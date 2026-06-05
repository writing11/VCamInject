# VCamInject

RootHide/rootless iOS camera replacement tweak.

## What this build does

- Injects into apps that use `AVCaptureVideoDataOutput`.
- Replaces camera sample buffers with a selected video.
- Two-finger quick double tap shows or hides a small floating red `Y` button.
- Tap the floating button to open the control menu.
- `Choose video and replace` opens the iOS photo video picker and enables replacement immediately after selection.
- `Restore real camera` disables replacement and returns the app to the real camera.
- Uses `PHPickerViewController`, so it avoids the common crash caused by host apps missing `NSPhotoLibraryUsageDescription`.
- Includes `vcamreceiverd`, a phone-side daemon that listens on TCP port `9999` for the Windows sender handshake.

## Phone controls

1. Open the target app camera page.
2. Tap the screen twice quickly with two fingers.
3. A floating red `Y` button appears.
4. Tap `VCam`.
5. Choose `Choose video and replace`.
6. Pick a video from the phone album.

The selected video is copied into the app temporary directory and is used immediately. There is no separate enable button.

To restore the real camera:

1. Tap the floating red `Y` button.
2. Choose `Restore real camera`.

## Priority order

The tweak uses sources in this order:

1. `/var/mobile/Library/VCam/frame.bgra` with `/var/mobile/Library/VCam/frame.info`
2. Video selected from the phone album in the current app process
3. `/var/mobile/Library/VCam/source.mp4`, `.mov`, or `.m4v`
4. Real camera

## Windows sender note

`vcamreceiverd` listens on port `9999` and acknowledges the Windows app handshake. It currently receives and saves the incoming H.264 stream to:

```text
/var/mobile/Library/VCam/stream.h264
```

Full live PC-video-to-camera replacement still requires decoding that H.264 stream into `frame.bgra` frames. The phone album replacement path works without the PC sender.

## Build with GitHub Actions

Upload the whole source folder to GitHub, including:

- `.github`
- `layout`
- `Makefile`
- `Tweak.xm`
- `VCamFrameProvider.h`
- `VCamFrameProvider.mm`
- `VCamVideoPicker.h`
- `VCamVideoPicker.mm`
- `VCamInject.plist`
- `vcamreceiverd.c`
- `control`
- `postinst`
- `prerm`

Then open:

```text
Actions -> Build RootHide Deb -> Run workflow
```

Download the `VCamInject-roothide-deb` artifact after the action succeeds.

## Install

Install the generated `.deb` with Sileo, Zebra, Filza, or:

```sh
dpkg -i com.qianmian.vcaminject_*.deb
```

Then restart the target app. If injection does not refresh, respring.

## Check the receiver daemon

On the phone terminal:

```sh
ps -A | grep vcamreceiver
cat /var/mobile/Library/VCam/vcamreceiver.log
cat /var/mobile/Library/VCam/vcamreceiver.err
```

If the Windows app still says the plugin is not listening, the daemon is not loaded or port forwarding is not reaching the device.
