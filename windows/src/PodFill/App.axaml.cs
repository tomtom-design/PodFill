using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using Avalonia.Threading;
using PodFill.Core;

namespace PodFill;

public partial class App : Application
{
    public override void Initialize() => AvaloniaXamlLoader.Load(this);

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            // The view model posts process output to the context it is created on: make sure it is the UI thread's.
            AvaloniaSynchronizationContext.InstallIfNeeded();
            desktop.MainWindow = new MainWindow(new MainViewModel(AppPlatform.Current));
        }
        base.OnFrameworkInitializationCompleted();
    }
}
