# UI tour

`HeyflareUITests` walks the app and attaches a screenshot at each stop. It expects a
simulator that is already signed in (see the repo's local worker fixture).

```sh
xcodebuild test -project Heyflare.xcodeproj -scheme Heyflare \
  -destination 'platform=iOS Simulator,id=<simulator>' \
  -only-testing:HeyflareUITests -resultBundlePath /tmp/tour.xcresult
xcrun xcresulttool export attachments --path /tmp/tour.xcresult --output-path /tmp/tour
```
