namespace DSPiConsole.Usb;

/// <summary>Caller serializes access. A scan can publish only for its originating hardware selection.</summary>
internal sealed class BackendModeState
{
    private long _generation;
    private bool _hardwareSelected;

    public void SelectHardware() { _generation++; _hardwareSelected = true; }
    public void SelectSoftware() { _generation++; _hardwareSelected = false; }
    public bool TryCaptureHardwareScan(out long generation)
    {
        generation = _generation;
        return _hardwareSelected;
    }
    public bool IsCurrentHardwareScan(long generation) => _hardwareSelected && generation == _generation;
}
