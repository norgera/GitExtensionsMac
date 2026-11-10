# GitExtensionsMac

<img width="1371" height="832" alt="GitExtensionsMac repository browser" src="https://github.com/user-attachments/assets/25df1d74-6fc9-47d6-b240-d760a6c6f5da" />

An unofficial, native macOS port of [Git Extensions](https://github.com/gitextensions/gitextensions), built with Swift and AppKit.

The goal is parity with Git Extensions: the same workflows, Git semantics, and layout, adapted to macOS conventions where Windows-only integrations do not apply.

> [!NOTE]
> GitExtensionsMac is an independent project and is not affiliated with or endorsed by the Git Extensions team. Please report issues with this port [here](https://github.com/norgera/GitExtensionsMac/issues), not to the upstream project.

## Status

Beta. Expect bugs, incomplete features, and UI differences from Git Extensions while development continues.

## Requirements

- macOS 14 or later
- Git available on your `PATH`
- Xcode 27 to build from source

## Installing

```sh
curl -fsSL https://raw.githubusercontent.com/norgera/GitExtensionsMac/main/Scripts/install.sh | bash
```

This downloads the latest release, copies the app to `/Applications`, and removes the quarantine attribute. Beta builds are not signed with an Apple Developer ID or notarized, so without this step macOS blocks the app on first launch and may say it is damaged.

### Manual install

Download the latest `.dmg` from [Releases](https://github.com/norgera/GitExtensionsMac/releases), drag `GitExtensionsMac.app` to `/Applications`, then run:

```sh
xattr -dr com.apple.quarantine /Applications/GitExtensionsMac.app
```

Alternatively, try to open the app once, then choose **Open Anyway** in **System Settings > Privacy & Security**.

## Building

Clone the repository, open `GitExtensionsMac.xcodeproj` in Xcode, and run the `GitExtensionsMac` scheme.

## Testing

```sh
Scripts/test.sh          # all suites
Scripts/test.sh unit     # unit tests only
Scripts/test.sh git      # Git integration tests
Scripts/test.sh ui       # UI integration tests
```

The tests create disposable repositories in a temporary directory and drive the real Git executable.

## Plugins

See [PLUGINS.md](PLUGINS.md) for the native plugin contract.

## License and credits

GitExtensionsMac is licensed under the [GNU General Public License v3.0](LICENSE), the same license as Git Extensions.

Git Extensions, its name, logo, and icon resources are the work of the [Git Extensions team and contributors](https://github.com/gitextensions/gitextensions/graphs/contributors). Some icons are by [Yusuke Kamiyamane](http://p.yusukekamiyamane.com/) (CC BY 3.0).
