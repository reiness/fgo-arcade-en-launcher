# FGO ARCADE - English launcher

An English launcher for the PC port of **Fate/Grand Order Arcade**, added *beside* the Chinese one you
already have. Your existing install is not modified: the English launcher reaches your game, accounts and
database through folder links, and the few files it needs sit next to the originals under their own names.
One command removes it again.

## What is translated - and what is not

**Translated:** the launcher window, its settings, the account and server tools it runs, its messages, and
the keyboard and controller guide pictures.

**Not translated:** the game itself. Story, servant names, quests and menus inside the game are unchanged.
The Chinese release's own localization is partial by design - see Known issues below.

## Before you install

| Requirement | Why |
| --- | --- |
| The Chinese version already installed and working | This is a patch, not the game |
| An **NVIDIA** graphics card | The game uses NVIDIA-only rendering; on Intel or AMD graphics it cannot enter the game at all |
| Your network on **192.168.x.x** | The game only deploys on that range |
| Windows 10 or 11 with PowerShell 5.1 | Ships with Windows |
| About 1 GB free space | For the download and the English launcher folder |

The installer checks all of these first and stops with a plain message rather than leaving you with a
broken game.

## Install

Paste this into Command Prompt or PowerShell:

```
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol='Tls12'; iex (irm https://raw.githubusercontent.com/reiness/fgo-arcade-en-launcher/main/install.ps1)"
```

It finds your install, checks your machine, downloads the patch (about 65 MB), checks the download against
its published fingerprint, and creates a folder called `FGO ARCADE EN` next to your install.

If your game is somewhere unusual, point it at the folder yourself:

```
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol='Tls12'; &([scriptblock]::Create((irm https://raw.githubusercontent.com/reiness/fgo-arcade-en-launcher/main/install.ps1))) -Install 'D:\FGO ARCADE'"
```

## Run it

Open the new `FGO ARCADE EN` folder, right-click `FGOLocalPlatform.exe` and choose **Run as administrator**.

Administrator is required. Without it the game stops at **ERROR 4102**, because the arcade service behind the
game has to write a Windows registry key and is refused otherwise.

## Uninstall

```
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol='Tls12'; &([scriptblock]::Create((irm https://raw.githubusercontent.com/reiness/fgo-arcade-en-launcher/main/install.ps1))) -Remove"
```

This deletes only what was added, and puts your install back exactly as it was. To reinstall or update,
remove it first, then install again.

## Rather not run a downloaded script?

That is a fair instinct. Do it by hand instead:

1. Download `fgo-en-launcher-v1.0.0.zip` and `install.ps1` from the [Releases](../../releases) page.
2. Unzip the patch anywhere.
3. Run `install.ps1 -Install "<your FGO ARCADE folder>" -PayloadPath "<the zip you downloaded>"`.

The release page lists the zip's SHA-256 so you can check it yourself before running anything.

## What it puts on your disk

A new `FGO ARCADE EN` folder holding the English launcher and links to your game, plus these files added
beside the originals inside your install - nothing existing is touched:

```
App\FGO_Launcher-en.ps1                                    the English launcher script
App\am\MSVCP110.dll, App\am\MSVCR110.dll                   the Visual C++ 2012 runtime the arcade service needs
App\manuals-en\keyboard-controls.png, controller-controls.png   the English control guides
Server\tools\fgo_account-en.py, fgo_server_config-en.py     the English account and server tools
Server\artemis\titles\fgo\data\summon_candidates-en.json    the English summon notes
```

Every one of those is listed, with its fingerprint, in `FGO ARCADE EN\english-launcher.json`, which is what
the uninstall reads. Both launchers share one set of accounts, one database and one copy of the game, so run
only one at a time.

## Known issues (from the Chinese release - not caused by this patch)

1. After finishing the tutorial, close the game **and** the server and re-enter. Otherwise the pillar quest
   is not issued in the first singularity and the main story gets stuck.
2. Integrated graphics and AMD cards cannot enter the game - it uses NVIDIA rendering technology.
3. Network cards outside the 192.168.x.x range may not deploy in one click.
4. The localization is partial; some text remains untranslated.
5. Some scenes have audio parsing problems.

## Credit

The PC port of FGO Arcade, the local platform and the server are the work of **Cloud23333**. This repository
only adds an English launcher on top of that work; it does not redistribute the game.