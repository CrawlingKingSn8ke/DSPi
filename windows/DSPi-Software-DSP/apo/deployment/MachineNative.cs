// GPL-3.0. Native primitives; callers bind every target to a generated scope.
using System;
using System.IO;
using System.Text;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;
namespace DspiMachine {
public static class Native {
 [StructLayout(LayoutKind.Sequential)] struct SA {public int Size;public IntPtr Descriptor;public int Inherit;}
 [StructLayout(LayoutKind.Sequential)] struct IFACE {public uint Size;public Guid Class;public uint Flags;public UIntPtr Reserved;}
 [StructLayout(LayoutKind.Sequential)] struct DEV {public uint Size;public Guid Class;public uint Instance;public UIntPtr Reserved;}
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string s,uint revision,out IntPtr p,out uint size);
 [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr p);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateDirectory(string p,ref SA s);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFile(string p,uint access,uint share,ref SA s,uint disposition,uint flags,IntPtr template);
 [DllImport("kernel32.dll",EntryPoint="CreateFileW",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle OpenFile(string p,uint access,uint share,IntPtr security,uint disposition,uint flags,IntPtr template);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateFileMapping(SafeFileHandle file,IntPtr security,uint protection,uint high,uint low,string name);
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode)] static extern int RegCreateKeyEx(IntPtr parent,string name,uint reserved,string cls,uint options,uint access,ref SA security,out IntPtr result,out uint disposition);
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode)] static extern int RegRenameKey(IntPtr parent,string from,string to);
 [DllImport("advapi32.dll")] static extern int RegCloseKey(IntPtr p);
 [DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr SetupDiGetClassDevs(ref Guid cls,string enumerator,IntPtr hwnd,uint flags);
 [DllImport("setupapi.dll",SetLastError=true)] static extern bool SetupDiEnumDeviceInterfaces(IntPtr set,IntPtr dev,ref Guid cls,uint index,ref IFACE data);
 [DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr set,ref IFACE data,IntPtr detail,uint size,out uint required,ref DEV dev);
 [DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool SetupDiGetDeviceInstanceId(IntPtr set,ref DEV dev,StringBuilder id,uint size,out uint needed);
 [DllImport("setupapi.dll",SetLastError=true)] static extern IntPtr SetupDiOpenDeviceInterfaceRegKey(IntPtr set,ref IFACE data,uint reserved,uint access);
 [DllImport("setupapi.dll")] static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
 [StructLayout(LayoutKind.Sequential)] struct Request {public uint Access;public IntPtr Self,Types;public uint TypeCount;public IntPtr Arguments;}
 [StructLayout(LayoutKind.Sequential)] struct Reply {public uint Count;public IntPtr Granted,Sacl,Error;}
 [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,int pid);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetProcessInformation(IntPtr process,int infoClass,out uint level,uint size);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr p);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool QueryFullProcessImageName(IntPtr p,uint flags,StringBuilder name,ref uint length);
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr p,uint access,out IntPtr token);
 [DllImport("authz.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool AuthzInitializeResourceManager(uint flags,IntPtr check,IntPtr groups,IntPtr free,string name,out IntPtr manager);
 [DllImport("authz.dll",SetLastError=true)] static extern bool AuthzInitializeContextFromToken(uint flags,IntPtr token,IntPtr manager,IntPtr expires,long id,IntPtr args,out IntPtr context);
 [DllImport("authz.dll",SetLastError=true)] static extern bool AuthzAccessCheck(uint flags,IntPtr context,ref Request request,IntPtr audit,IntPtr descriptor,IntPtr optional,uint count,ref Reply reply,IntPtr results);
 [DllImport("authz.dll")] static extern bool AuthzFreeContext(IntPtr context);
 [DllImport("authz.dll")] static extern bool AuthzFreeResourceManager(IntPtr manager);
 static SA Security(string text){IntPtr p;uint n;if(!ConvertStringSecurityDescriptorToSecurityDescriptor(text,1,out p,out n))throw new Win32Exception();return new SA{Size=Marshal.SizeOf(typeof(SA)),Descriptor=p};}
 static void Leaf(string s){if(String.IsNullOrEmpty(s)||s.Contains("\\")||s.Contains("/")||s=="."||s=="..")throw new ArgumentException("Expected one key name");}
 public static void Directory(string path,string sddl){var s=Security(sddl);try{if(!CreateDirectory(path,ref s))throw new Win32Exception();}finally{LocalFree(s.Descriptor);}}
 public static void File(string path,byte[] bytes,string sddl){WriteFileCore(path,bytes,sddl,false);}
 public static void TestFileWriteFailure(string path,byte[] bytes,string sddl){WriteFileCore(path,bytes,sddl,true);}
 static void WriteFileCore(string path,byte[] bytes,string sddl,bool fail){var s=Security(sddl);bool created=false;try{using(var h=CreateFile(path,0x40000000,0,ref s,1,0x80000000,IntPtr.Zero)){if(h.IsInvalid)throw new Win32Exception();created=true;using(var f=new FileStream(h,FileAccess.Write)){if(fail){f.Write(bytes,0,Math.Min(1,bytes.Length));f.Flush(true);throw new IOException("Injected native file-write failure");}f.Write(bytes,0,bytes.Length);f.Flush(true);}}}catch(Exception error){if(created){try{System.IO.File.Delete(path);}catch(Exception cleanup){error.Data["DspiOwnedFilePath"]=path;error.Data["DspiCleanupFailure"]=cleanup.Message;}}throw;}finally{LocalFree(s.Descriptor);}}
 public static RegistryKey Key(RegistryKey parent,string leaf,string sddl){Leaf(leaf);var s=Security(sddl);IntPtr h=IntPtr.Zero;try{uint disposition;int e=RegCreateKeyEx(parent.Handle.DangerousGetHandle(),leaf,0,null,0,0x3001f,ref s,out h,out disposition);if(e!=0)throw new Win32Exception(e);if(disposition!=1){RegCloseKey(h);h=IntPtr.Zero;throw new IOException("Registry destination already exists");}var key=RegistryKey.FromHandle(new SafeRegistryHandle(h,true),RegistryView.Registry64);h=IntPtr.Zero;return key;}finally{if(h!=IntPtr.Zero)RegCloseKey(h);LocalFree(s.Descriptor);}}
 public static void Rename(RegistryKey parent,string from,string to){Leaf(from);Leaf(to);int e=RegRenameKey(parent.Handle.DangerousGetHandle(),from,to);if(e!=0)throw new Win32Exception(e);parent.Flush();}
 public static void ExecutableMapping(string path){using(var file=OpenFile(path,0xa0000000,7,IntPtr.Zero,3,0x80,IntPtr.Zero)){if(file.IsInvalid)throw new Win32Exception();IntPtr map=CreateFileMapping(file,IntPtr.Zero,0x20,0,0,null);if(map==IntPtr.Zero)throw new Win32Exception();CloseHandle(map);}}
 public static bool AudioAccess(int pid,string sddl,uint desired,bool requireUnprotected=false){
  return AudioAccessResult(pid,sddl,desired,requireUnprotected)=="Allowed";
 }
 public static string AudioAccessResult(int pid,string sddl,uint desired,bool requireUnprotected=false){
  IntPtr process=OpenProcess(0x1000,false,pid);if(process==IntPtr.Zero)return "OpenProcess:"+Marshal.GetLastWin32Error();
  IntPtr token=IntPtr.Zero,manager=IntPtr.Zero,context=IntPtr.Zero,buffer=IntPtr.Zero;SA security=new SA();
  try{
   var image=new StringBuilder(4096);uint size=4096;if(!QueryFullProcessImageName(process,0,image,ref size))return "ImageQuery:"+Marshal.GetLastWin32Error();
   if(!String.Equals(image.ToString(),Path.Combine(Environment.SystemDirectory,"audiodg.exe"),StringComparison.OrdinalIgnoreCase))return "UnexpectedImage";
   uint level;
   if(requireUnprotected && (!GetProcessInformation(process,7,out level,4) || level!=0xfffffffeu))return "ProtectionLevel";
   if(!OpenProcessToken(process,8,out token))return "OpenProcessToken:"+Marshal.GetLastWin32Error();
   using(var identity=new WindowsIdentity(token)){if(identity.User==null||identity.User.Value!="S-1-5-19")return "UnexpectedTokenOwner";}
   if(!AuthzInitializeResourceManager(1,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,"DSPi rehearsal",out manager))return "AuthzManager:"+Marshal.GetLastWin32Error();
   if(!AuthzInitializeContextFromToken(0,token,manager,IntPtr.Zero,0,IntPtr.Zero,out context))return "AuthzContext:"+Marshal.GetLastWin32Error();
   security=Security(sddl);buffer=Marshal.AllocHGlobal(8);
   Marshal.WriteInt64(buffer,0);
   var request=new Request{Access=desired};
   var reply=new Reply{Count=1,Granted=buffer,Error=IntPtr.Add(buffer,4)};
   if(!AuthzAccessCheck(0,context,ref request,IntPtr.Zero,security.Descriptor,IntPtr.Zero,0,ref reply,IntPtr.Zero))return "AuthzAccessCheck:"+Marshal.GetLastWin32Error();
   int error=Marshal.ReadInt32(reply.Error);
   return error==0 && ((uint)Marshal.ReadInt32(reply.Granted)&desired)==desired ? "Allowed" : "Denied:"+error;
  }finally{if(buffer!=IntPtr.Zero)Marshal.FreeHGlobal(buffer);if(security.Descriptor!=IntPtr.Zero)LocalFree(security.Descriptor);if(context!=IntPtr.Zero)AuthzFreeContext(context);if(manager!=IntPtr.Zero)AuthzFreeResourceManager(manager);if(token!=IntPtr.Zero)CloseHandle(token);CloseHandle(process);}
 }
 public static RegistryKey Interface(string path,string instance,bool write){return Interface(path,instance,write,true);}
 public static RegistryKey Interface(string path,string instance,bool write,bool present){
  if(!instance.StartsWith("USB\\VID_2E8B&PID_FEAA&MI_00\\",StringComparison.OrdinalIgnoreCase)||!path.EndsWith("\\global",StringComparison.OrdinalIgnoreCase))throw new ArgumentException("Unsupported interface scope");
  Guid cls=new Guid("6994ad04-93ef-11d0-a3cc-00a0c9223196");IntPtr set=SetupDiGetClassDevs(ref cls,null,IntPtr.Zero,present?18u:16u);if(set==new IntPtr(-1))throw new Win32Exception();
  try{for(uint i=0;;i++){
   var data=new IFACE{Size=(uint)Marshal.SizeOf(typeof(IFACE))};if(!SetupDiEnumDeviceInterfaces(set,IntPtr.Zero,ref cls,i,ref data)){int e=Marshal.GetLastWin32Error();if(e==259)break;throw new Win32Exception(e);}
   var dev=new DEV{Size=(uint)Marshal.SizeOf(typeof(DEV))};uint required;bool ok=SetupDiGetDeviceInterfaceDetail(set,ref data,IntPtr.Zero,0,out required,ref dev);int err=Marshal.GetLastWin32Error();if(ok||err!=122||required<8||required>65536)throw new IOException("Invalid interface detail size");
   IntPtr detail=Marshal.AllocHGlobal((int)required);try{
    Marshal.WriteInt32(detail,IntPtr.Size==8?8:6);if(!SetupDiGetDeviceInterfaceDetail(set,ref data,detail,required,out required,ref dev))throw new Win32Exception();
    if(!String.Equals(path,Marshal.PtrToStringUni(IntPtr.Add(detail,4)),StringComparison.OrdinalIgnoreCase))continue;
    var id=new StringBuilder(1024);uint needed;if(!SetupDiGetDeviceInstanceId(set,ref dev,id,1024,out needed))throw new Win32Exception();if(!String.Equals(id.ToString(),instance,StringComparison.OrdinalIgnoreCase))throw new IOException("Interface function identity changed");
    IntPtr h=SetupDiOpenDeviceInterfaceRegKey(set,ref data,0,write?0x2001fu:0x20019u);if(h==new IntPtr(-1))throw new Win32Exception();return RegistryKey.FromHandle(new SafeRegistryHandle(h,true),RegistryView.Registry64);
   }finally{Marshal.FreeHGlobal(detail);}
  }throw new IOException("Selected active interface is unavailable");}finally{SetupDiDestroyDeviceInfoList(set);}
 }
}
}
