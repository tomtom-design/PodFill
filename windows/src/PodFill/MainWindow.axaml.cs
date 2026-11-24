using System.ComponentModel;
using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Platform.Storage;
using PodFill.Core;

namespace PodFill;

public partial class MainWindow : Window
{
    private readonly MainViewModel _vm;
    private bool _closeWhenIdle;

    // Parameterless constructor for the XAML designer.
    public MainWindow() : this(new MainViewModel(AppPlatform.Current)) { }

    public MainWindow(MainViewModel vm)
    {
        _vm = vm;
        DataContext = vm;
        InitializeComponent();
        vm.PropertyChanged += OnModelChanged;
        Closing += OnClosing;
    }

    private void OnModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        // Keep the log scrolled to the newest line.
        if (e.PropertyName == nameof(MainViewModel.Log) && LogBox.Text is { } text) LogBox.CaretIndex = text.Length;
    }

    private async void OnChooseFolder(object? sender, RoutedEventArgs e)
    {
        var start = Directory.Exists(_vm.Destination) ? _vm.Destination : Path.GetDirectoryName(_vm.Destination);
        var options = new FolderPickerOpenOptions { Title = "Save music to", AllowMultiple = false };
        if (start is not null && await StorageProvider.TryGetFolderFromPathAsync(start) is { } folder)
            options.SuggestedStartLocation = folder;
        var picked = await StorageProvider.OpenFolderPickerAsync(options);
        if (picked.Count > 0 && picked[0].TryGetLocalPath() is { } path) _vm.Destination = path;
    }

    /// <summary>Closing mid-download: stop spotdl first and let the run delete its half-written files, then close.</summary>
    private async void OnClosing(object? sender, WindowClosingEventArgs e)
    {
        if (_closeWhenIdle || !_vm.IsBusy) return;
        e.Cancel = true;
        _closeWhenIdle = true;
        Title = "PodFill (stopping…)";
        await _vm.ShutdownAsync();
        Close();
    }
}
