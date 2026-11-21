using Dspi.Audio.Core;
int checks=0;
void Check(bool c,string label){checks++;if(!c)throw new Exception(label);}
void Reject(Action a,string label){try{a();}catch(ArgumentException){checks++;return;}throw new Exception(label);}
AudioProcessCallback identity=(input,output,n)=>Array.Copy(input,output,n*2);
Reject(()=>new AdaptiveAudioPipeline(48000,2,48000,2,48000,2,[0,2],identity),"Invalid route accepted");
Reject(()=>new AdaptiveAudioPipeline(48000,2,48000,2,48000,2,[0,1],identity,new(){TargetBufferMilliseconds=600}),"Unbounded latency accepted");
var p=new AdaptiveAudioPipeline(48000,2,48000,2,48000,2,[1,0],identity,new(){TargetBufferMilliseconds=20});
var block=new float[480*2];var output=new float[480*2];
p.Render(output,0,480);Check(output.All(x=>x==0)&&p.Statistics.UnderrunCount==0,"Initial priming not silent");
for(int i=0;i<480;i++){block[i*2]=.2f;block[i*2+1]=-.4f;}
for(int b=0;b<5;b++)p.PushCapture(block,0,480);
for(int b=0;b<4;b++)p.Render(output,0,480);
Check(Math.Abs(output[^2]+.4f)<.0001&&Math.Abs(output[^1]-.2f)<.0001,"DSP channel mapping/DC fidelity");
Check(p.Statistics.CapturedFrames==2400&&p.Statistics.RenderedFrames==2400,"Frame counters incorrect");
// Underrun fades to silence and buffers again without stale replay.
for(int b=0;b<12;b++)p.Render(output,0,480);
Check(p.Statistics.UnderrunCount==1&&output.All(x=>x==0)&&!p.Statistics.Primed,"Underrun recovery failed");
for(int b=0;b<4;b++)p.PushCapture(block,0,480);
p.Render(output,0,480);Check(p.Statistics.Primed,"Repriming failed");
p.RequestStop();for(int b=0;b<5;b++)p.Render(output,0,480);Check(p.StopFadeCompleted&&output.All(x=>x==0),"Stop did not fade to silence");
// Oversized capture packets must be dropped, not resize a callback buffer.
var over=new AdaptiveAudioPipeline(48000,2,48000,2,48000,2,[0,1],identity,new(){TargetBufferMilliseconds=20,CapacityMilliseconds=100});
over.PushCapture(new float[10000*2],0,10000);Check(over.Statistics.OverrunCount==1&&over.Statistics.DroppedCaptureFrames==10000,"Overrun not bounded/reported");
block[0]=float.NaN;over.PushCapture(block,0,480);Check(over.Statistics.InvalidSamples==1,"Bad capture sample was not sanitized");block[0]=.2f;
// Both SRC directions: source96k -> engine48k -> output44.1k. A tone retains pitch.
var src=new AdaptiveAudioPipeline(96000,2,48000,2,44100,2,[0,1],identity,new(){TargetBufferMilliseconds=20});
var capture=new float[960*2];var render=new float[441*2];double power=0;int samples=0,crossings=0;float prior=0;
for(int b=0;b<130;b++){
 for(int i=0;i<960;i++){float v=.2f*MathF.Sin(2*MathF.PI*1000*(b*960+i)/96000);capture[2*i]=capture[2*i+1]=v;}
 src.PushCapture(capture,0,960);src.Render(render,0,441);
 if(b>20)for(int i=0;i<441;i++){float v=render[2*i];power+=v*v;samples++;if(prior<=0&&v>0)crossings++;prior=v;}
}
double rms=Math.Sqrt(power/samples),frequency=crossings*44100.0/samples;
Check(Math.Abs(rms-.2/Math.Sqrt(2))<.003,$"SRC amplitude {rms}");Check(Math.Abs(frequency-1000)<3,$"SRC pitch {frequency}");
Check(src.Statistics.UnderrunCount==0&&src.Statistics.OverrunCount==0,"SRC constant-rate stream dropped audio");
// Downsampling rejects out-of-band source frequencies instead of folding them.
double Measure(float hz){var q=new AdaptiveAudioPipeline(96000,2,48000,2,48000,2,[0,1],identity,new(){TargetBufferMilliseconds=20});double sum=0;int n=0;var a=new float[960*2];var z=new float[480*2];for(int b=0;b<40;b++){for(int i=0;i<960;i++)a[2*i]=a[2*i+1]=.2f*MathF.Sin(2*MathF.PI*hz*(b*960+i)/96000);q.PushCapture(a,0,960);q.Render(z,0,480);if(b>10)foreach(var v in z){sum+=v*v;n++;}}return Math.Sqrt(sum/n);}
double alias=Measure(30000),pass=Measure(1000);Check(20*Math.Log10(alias/pass)<-45,$"SRC alias rejection {20*Math.Log10(alias/pass)} dB");
double MeasureNarrow(float hz){var q=new AdaptiveAudioPipeline(48000,2,48000,2,8000,2,[0,1],identity,new(){TargetBufferMilliseconds=20});double sum=0;int n=0;var a=new float[480*2];var z=new float[80*2];for(int b=0;b<100;b++){for(int i=0;i<480;i++)a[2*i]=a[2*i+1]=.2f*MathF.Sin(2*MathF.PI*hz*(b*480+i)/48000);q.PushCapture(a,0,480);q.Render(z,0,80);if(b>30)foreach(var v in z){sum+=v*v;n++;}}return Math.Sqrt(sum/n);}
double narrowAlias=MeasureNarrow(4400),narrowPass=MeasureNarrow(1000);Check(20*Math.Log10(narrowAlias/narrowPass)<-45,$"6:1 downsample alias rejection {20*Math.Log10(narrowAlias/narrowPass)} dB");
// A faster capture clock must be corrected without unbounded growth or drops.
var drift=new AdaptiveAudioPipeline(48000,2,48000,2,48000,2,[0,1],identity,new(){TargetBufferMilliseconds=40});
var extra=new float[481*2];double carry=0;
for(int b=0;b<15000;b++){carry+=.144;int n=480;if(carry>=1){carry--;n++;}drift.PushCapture(extra,0,n);drift.Render(output,0,480);}
Check(drift.Statistics.CorrectionPpm>50&&drift.Statistics.CorrectionPpm<=1500,"Capture clock drift not corrected");
Check(drift.Statistics.BufferedMilliseconds<100&&drift.Statistics.UnderrunCount==0&&drift.Statistics.OverrunCount==0,"Clock drift caused a dropout or runaway buffer");
// Warm callback path is allocation-free with a non-allocating processor.
long before=GC.GetAllocatedBytesForCurrentThread();for(int b=0;b<100;b++){drift.PushCapture(block,0,480);drift.Render(output,0,480);}long allocated=GC.GetAllocatedBytesForCurrentThread()-before;
Check(allocated==0,$"Audio callback allocated {allocated} bytes");
var slow=new AdaptiveAudioPipeline(48000,2,48000,2,48000,2,[0,1],identity,new(){TargetBufferMilliseconds=40});carry=0;
for(int b=0;b<15000;b++){carry-=.144;int n=480;if(carry<=-1){carry++;n--;}slow.PushCapture(extra,0,n);slow.Render(output,0,480);}
Check(slow.Statistics.CorrectionPpm< -50&&slow.Statistics.CorrectionPpm>=-1500,"Slower capture clock not corrected");
Check(slow.Statistics.UnderrunCount==0&&slow.Statistics.OverrunCount==0&&slow.Statistics.BufferedMilliseconds<100,"Negative clock drift dropped audio");
// Real producer/consumer overlap must not tear channel frames.
var concurrent=new AdaptiveAudioPipeline(48000,2,48000,2,48000,2,[0,1],identity,new(){TargetBufferMilliseconds=40});var stereo=new float[960];for(int i=0;i<480;i++){stereo[2*i]=.2f;stereo[2*i+1]=-.2f;}for(int i=0;i<5;i++)concurrent.PushCapture(stereo,0,480);
using(var barrier=new Barrier(2)){
 var producer=Task.Run(()=>{for(int i=0;i<1000;i++){barrier.SignalAndWait();concurrent.PushCapture(stereo,0,480);barrier.SignalAndWait();}});
 for(int i=0;i<1000;i++){barrier.SignalAndWait();concurrent.Render(output,0,480);barrier.SignalAndWait();for(int f=0;f<480;f++)if(!float.IsFinite(output[2*f])||Math.Abs(output[2*f]+output[2*f+1])>1e-6)throw new Exception("Concurrent FIFO tore a frame");}
 producer.GetAwaiter().GetResult();
}
Check(concurrent.Statistics.UnderrunCount==0&&concurrent.Statistics.OverrunCount==0,"Concurrent callbacks caused a dropout");
if(OperatingSystem.IsWindows()){
 // Capture44.1 -> adaptive48k -> REAL native8-outputDSP -> mapped96k render.
 var config=new Dspi.Software.EngineConfiguration {OutputCount=8};config.Routes[7].Enabled=true;config.Outputs[7].GainDb=-6;
 using var native=new Dspi.Software.NativeSession(config);
 var live=new AdaptiveAudioPipeline(44100,2,48000,8,96000,2,[7,1],native.Process,new(){TargetBufferMilliseconds=20});
 var a=new float[441*2];var z=new float[960*2];double left=0,right=0;int count=0;
 for(int b=0;b<100;b++){
  for(int i=0;i<441;i++){a[2*i]=.2f*MathF.Sin(2*MathF.PI*1000*(b*441+i)/44100);a[2*i+1]=.1f*MathF.Sin(2*MathF.PI*2000*(b*441+i)/44100);}
  if(b==50){var edit=config.Clone();edit.Outputs[7].GainDb=-12;native.Apply(edit);}
  live.PushCapture(a,0,441);live.Render(z,0,960);
  if(b>70)for(int i=0;i<960;i++){left+=z[2*i]*z[2*i];right+=z[2*i+1]*z[2*i+1];count++;}
 }
 Check(Math.Abs(Math.Sqrt(left/count)-.2*Math.Pow(10,-12/20.0)/Math.Sqrt(2))<.001,"Live pipeline/native edit/output7 mapping failed");
 Check(Math.Abs(Math.Sqrt(right/count)-.1/Math.Sqrt(2))<.001,"Mapped right output changed");
 Check(native.ReadMeters().Outputs[7]>.02f,"Live pipeline did not feed real native meters");
 Check(live.Statistics.UnderrunCount==0&&live.Statistics.OverrunCount==0,"Real native pipeline dropped audio");
}
Console.WriteLine($"PASS: {checks} audio-core checks; SRC {frequency:F2} Hz / {rms:F6} RMS, alias {20*Math.Log10(alias/pass):F1} dB, drift {drift.Statistics.CorrectionPpm:F1} ppm.");
