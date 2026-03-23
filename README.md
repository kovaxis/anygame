
# AnyGame

## What?

AnyGame is an app designed to run [Love2D](https://love2d.org/) games on your phone, from the network.
The main use case for this app is to prototype a game in your computer and quickly stream it to your phone.

## How?

1. First, install the app on your phone.
    A pre-built APK is available on the GitHub releases page.
    [Quick download link](https://github.com/kovaxis/anygame/releases/download/0.1/anygame-aligned-debugSigned.apk)
    iOS builds are not currently provided as I do not have experience with the platform, but contributions are welcome.

2. Run the server on your computer.
    To do this, clone or download this repo, and run `python3 serve.py [path to directory containing main.lua]` in the console. You may need to install Python on Windows.

3. Connect your phone and computer to the same network.

4. Figure out the IP of your computer.
    You can do this using the `ip address` command on Unix or `ipconfig` on Windows.

5. Open the app on your phone and enter the IP of your computer when prompted.

6. Play!
    To reload the game, close and reopen the mobile app.
