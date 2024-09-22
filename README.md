
# AnyGame

## What?

AnyGame is an app designed to run Love2D games from the network.
The main use case for this app is to prototype a game in your computer and quickly stream it to your phone.

## How?

1. First, install the app on your phone.
    Currently only Android is supported.
    APK link: https://drive.google.com/file/d/1Jr4Pxr2mGJsM8Z7xd-qfjHgT2uUpvvWB

2. Run the server on your computer.
    To do this, run `python3 serve.py [path to directory containing main.lua]`

3. Connect your phone and computer to the same network.

4. Figure out the IP of your computer.
    You can do this using the `ifconfig` command.

5. Open the app on your phone and enter the IP of your computer.

6. Play!
    To reload the game, close and reopen the mobile app.
