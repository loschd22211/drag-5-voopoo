using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using Microsoft.Win32;

namespace GlassDock;

public class Entry
{
    public string Name { get; set; } = "";
    public string Path { get; set; } = "";
}
public class Group
{
    public string Name { get; set; } = "Приложения";
    public List<Entry> Items { get; set; } = new();
}
public static class Program
{
    [STAThread]
    public static void Main()
    {
        var app = new Application();
        app.Run(new Dock());
    }
}
public class Dock : Window
{
    readonly string config = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "GlassDock", "groups.json");
    List<Group> groups = new();
    readonly StackPanel dock = new() { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
    readonly Border panel = Surface();
    readonly StackPanel content = new();
    readonly ScaleTransform scale = new(1, 1);
    Group? active;
    bool closing;
    static Border Surface() => new()
    {
        Background = new SolidColorBrush(Color.FromArgb(238, 35, 39, 49)),
        BorderBrush = new SolidColorBrush(Color.FromArgb(110, 220, 230, 255)),
        BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(22), Padding = new Thickness(12), Margin = new Thickness(6)
    };
    public Dock()
    {
        Title = "GlassDock";
        WindowStyle = WindowStyle.None; AllowsTransparency = true; Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize; ShowInTaskbar = true; Topmost = false;
        SizeToContent = SizeToContent.WidthAndHeight;
        MaxWidth = SystemParameters.WorkArea.Width;
        panel.Child = content; panel.Visibility = Visibility.Collapsed;
        panel.RenderTransform = scale; panel.RenderTransformOrigin = new Point(.5, 1);
        var root = new StackPanel(); root.Children.Add(panel);
        var bar = Surface(); bar.Child = dock; root.Children.Add(bar); Content = root;
        try
        {
            if (File.Exists(config)) groups = JsonSerializer.Deserialize<List<Group>>(File.ReadAllText(config)) ?? new();
            if (groups.Any(g => g is null || g.Items is null || g.Items.Any(i => i is null))) throw new InvalidDataException("Invalid groups");
        }
        catch (Exception ex)
        {
            MessageBox.Show("Не удалось прочитать настройки. Файл не будет перезаписан.\n" + ex.Message);
            Loaded += (_, _) => Close(); return;
        }
        RenderDock();
        SizeChanged += (_, _) => Place();
        Loaded += (_, _) => Place();
        PreviewKeyDown += (_, e) => { if (e.Key == System.Windows.Input.Key.Escape) HidePanel(); };
        var menu = new ContextMenu();
        var exit = new MenuItem { Header = "Закрыть GlassDock" }; exit.Click += (_, _) => Close(); menu.Items.Add(exit);
        bar.ContextMenu = menu;
    }
    void Place()
    {
        var area = SystemParameters.WorkArea;
        Left = area.Left + Math.Max(0, (area.Width - ActualWidth) / 2);
        Top = area.Bottom - ActualHeight - 8;
    }
    Button Button(string text, Action action, double width = 72)
    {
        var button = new Button
        {
            Content = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center },
            Width = width, MinHeight = 56, Margin = new Thickness(4), Padding = new Thickness(6),
            Background = new SolidColorBrush(Color.FromRgb(60, 66, 82)), Foreground = Brushes.White,
            BorderThickness = new Thickness(0), Cursor = System.Windows.Input.Cursors.Hand
        };
        var border = new FrameworkElementFactory(typeof(Border));
        border.SetValue(Border.CornerRadiusProperty, new CornerRadius(14));
        border.SetBinding(Border.BackgroundProperty, new System.Windows.Data.Binding("Background") { RelativeSource = new System.Windows.Data.RelativeSource(System.Windows.Data.RelativeSourceMode.TemplatedParent) });
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        presenter.SetValue(FrameworkElement.HorizontalAlignmentProperty, HorizontalAlignment.Center);
        presenter.SetValue(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Center);
        border.AppendChild(presenter);
        button.Template = new ControlTemplate(typeof(Button)) { VisualTree = border };
        button.Click += (_, _) => action(); return button;
    }
    bool Save()
    {
        try
        {
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(config)!);
            var temp = config + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(groups, new JsonSerializerOptions { WriteIndented = true }));
            File.Move(temp, config, true); return true;
        }
        catch (Exception ex) { MessageBox.Show("Не удалось сохранить настройки:\n" + ex.Message); return false; }
    }
    void RenderDock()
    {
        dock.Children.Clear();
        foreach (var group in groups)
        {
            var button = Button("▦\n" + group.Name, () => Open(group));
            var menu = new ContextMenu();
            var remove = new MenuItem { Header = "Удалить группу (не файлы)" };
            remove.Click += (_, _) =>
            {
                if (MessageBox.Show("Удалить группу «" + group.Name + "»? Сами файлы останутся.", "GlassDock", MessageBoxButton.YesNo) != MessageBoxResult.Yes) return;
                groups.Remove(group); Save(); HidePanel(); RenderDock();
            };
            menu.Items.Add(remove); button.ContextMenu = menu; dock.Children.Add(button);
        }
        dock.Children.Add(Button("+", () =>
        {
            if (groups.Count >= 10) { MessageBox.Show("В первой версии доступно до 10 групп."); return; }
            var g = new Group { Name = "Папка " + (groups.Count + 1) }; groups.Add(g); Save(); RenderDock(); Open(g);
        }, 48));
    }
    void Open(Group group)
    {
        if (active == group && panel.Visibility == Visibility.Visible && !closing) { HidePanel(); return; }
        closing = false; active = group;
        panel.BeginAnimation(OpacityProperty, null); scale.BeginAnimation(ScaleTransform.ScaleYProperty, null);
        content.Children.Clear();
        var name = new TextBox { Text = group.Name, MaxLength = 40, Margin = new Thickness(4), FontSize = 17 };
        name.LostKeyboardFocus += (_, _) => { group.Name = string.IsNullOrWhiteSpace(name.Text) ? "Папка" : name.Text.Trim(); Save(); RenderDock(); };
        content.Children.Add(name);
        var grid = new WrapPanel { Width = Math.Min(480, Math.Max(120, SystemParameters.WorkArea.Width - 64)) };
        foreach (var entry in group.Items)
        {
            var button = Button(entry.Name, () => Launch(entry), 108); button.ToolTip = entry.Path;
            var menu = new ContextMenu(); var remove = new MenuItem { Header = "Убрать ярлык (не файл)" };
            remove.Click += (_, _) => { group.Items.Remove(entry); Save(); active = null; Open(group); };
            menu.Items.Add(remove); button.ContextMenu = menu; grid.Children.Add(button);
        }
        content.Children.Add(new ScrollViewer { Content = grid, MaxHeight = Math.Max(100, SystemParameters.WorkArea.Height - 250), VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        var actions = new StackPanel { Orientation = Orientation.Horizontal };
        actions.Children.Add(Button("+ Ярлыки", () => AddFiles(group), 110));
        actions.Children.Add(Button("+ Папка", () => AddFolder(group), 110));
        actions.Children.Add(Button("Свернуть", HidePanel, 110)); content.Children.Add(actions);
        panel.Visibility = Visibility.Visible;
        Animate(0, 1, .92, 1, null);
    }
    void Animate(double from, double to, double scaleFrom, double scaleTo, Action? done)
    {
        var duration = TimeSpan.FromMilliseconds(SystemParameters.ClientAreaAnimation ? 180 : 1);
        var fade = new DoubleAnimation(from, to, duration) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } };
        if (done != null) fade.Completed += (_, _) => done();
        scale.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(scaleFrom, scaleTo, duration) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } });
        panel.BeginAnimation(OpacityProperty, fade);
    }
    void HidePanel()
    {
        if (closing || panel.Visibility != Visibility.Visible) return;
        closing = true;
        Animate(panel.Opacity, 0, scale.ScaleY, .95, () => { panel.Visibility = Visibility.Collapsed; active = null; closing = false; });
    }
    void AddFiles(Group group)
    {
        var picker = new OpenFileDialog { Multiselect = true, DereferenceLinks = false, Filter = "Ярлыки и программы|*.lnk;*.exe|Все файлы|*.*" };
        if (picker.ShowDialog(this) != true) return;
        foreach (var path in picker.FileNames)
            if (!group.Items.Any(i => i.Path.Equals(path, StringComparison.OrdinalIgnoreCase)))
                group.Items.Add(new Entry { Name = System.IO.Path.GetFileNameWithoutExtension(path), Path = path });
        Save(); active = null; Open(group);
    }
    void AddFolder(Group group)
    {
        var picker = new OpenFolderDialog();
        if (picker.ShowDialog(this) != true) return;
        group.Items.Add(new Entry { Name = System.IO.Path.GetFileName(picker.FolderName), Path = picker.FolderName });
        Save(); active = null; Open(group);
    }
    void Launch(Entry entry)
    {
        try
        {
            if (!File.Exists(entry.Path) && !Directory.Exists(entry.Path)) { MessageBox.Show("Файл или папка не найдены:\n" + entry.Path); return; }
            Process.Start(new ProcessStartInfo(entry.Path) { UseShellExecute = true }); HidePanel();
        }
        catch (Exception ex) { MessageBox.Show("Не удалось открыть:\n" + ex.Message); }
    }
}
