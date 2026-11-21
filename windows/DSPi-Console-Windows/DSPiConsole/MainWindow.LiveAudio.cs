using Microsoft.UI.Xaml;

namespace DSPiConsole;

public sealed partial class MainWindow
{
    private LiveAudioWindow? _liveAudioWindow;
    private bool _liveAudioClosePending;
    private void OnLiveAudioClick(object sender, RoutedEventArgs e)
    {
        if (!ViewModel.Device.IsSoftwareMode || ViewModel.Device.IsWindowsApo || _softwareFileBusy) return;
        if (_liveAudioWindow == null)
        {
            _liveAudioWindow = new LiveAudioWindow(ViewModel);
            _liveAudioWindow.StateChanged += (_, _) => ApplySoftwareMenuState();
            _liveAudioWindow.Closed += (_, _) => { _liveAudioWindow = null; ApplySoftwareMenuState(); };
        }
        _liveAudioWindow.Activate();
    }
    private async Task StopLiveAudioAsync()
    {
        if (_liveAudioWindow != null) await _liveAudioWindow.StopAsync();
    }
}
