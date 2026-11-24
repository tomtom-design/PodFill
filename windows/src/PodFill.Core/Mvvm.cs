using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows.Input;

namespace PodFill.Core;

public abstract class ObservableObject : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Raise(name);
        return true;
    }

    protected void Raise([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

public sealed class RelayCommand(Action execute, Func<bool>? canExecute = null) : ICommand
{
    public event EventHandler? CanExecuteChanged;
    public bool CanExecute(object? parameter) => canExecute?.Invoke() ?? true;
    public void Execute(object? parameter) { if (CanExecute(parameter)) execute(); }
    public void NotifyCanExecuteChanged() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);
}

/// <summary>One row of the song list.</summary>
public sealed class SongRow(string name, SongStatus status) : ObservableObject
{
    private SongStatus _status = status;

    public string Name { get; } = name;

    public SongStatus Status
    {
        get => _status;
        set
        {
            if (!Set(ref _status, value)) return;
            Raise(nameof(Label));
            Raise(nameof(Glyph));
            Raise(nameof(IsDone));
            Raise(nameof(IsFailed));
            Raise(nameof(IsAlreadyHad));
            Raise(nameof(IsActive));
        }
    }

    public string Label => Status.Label;

    public string Glyph => Status.State switch
    {
        SongState.Searching => "…",     // …
        SongState.Downloading => "↓",   // ↓
        SongState.Tagging => "✎",       // ✎
        SongState.Done => "✔",          // ✔
        SongState.AlreadyHad => "✓",    // ✓
        _ => "✖",                       // ✖
    };

    public bool IsDone => Status.State == SongState.Done;
    public bool IsFailed => Status.State == SongState.Failed;
    public bool IsAlreadyHad => Status.State == SongState.AlreadyHad;
    public bool IsActive => !Status.IsFinished;
}
