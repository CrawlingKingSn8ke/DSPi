using DSPiConsole.Core.Rta;

namespace DSPiConsole.Usb;

public partial class DspDevice : IRtaTransport
{
    public byte[]? RtaIn(byte request, ushort value, int length)
    {
        lock (_lock)
            return _windowsApoSpectrum != null
                ? _windowsApoSpectrum.Read(request, value, length)
                : ControlTransferIn(request, value, length);
    }

    public bool RtaOut(byte request, ushort value, byte[] data)
    {
        lock (_lock)
            return _windowsApoSpectrum != null
                ? request == RtaWire.SetConfig && RtaConfig.Parse(data) is { } config && _windowsApoSpectrum.Configure(config)
                : ControlTransferOut(request, value, data);
    }
}

