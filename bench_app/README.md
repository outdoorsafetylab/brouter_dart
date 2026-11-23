# brouter_bench

Stage 3 of `docs/design.md` D6: runs the layer-3 golden routes on a phone, three rounds in a background isolate, checks every point against Java and prints the times (`BENCH` lines in the console or logcat, and `bench.txt` in the app's documents).

```shell
./prepare.sh                      # copies the golden inputs into assets/ (35 MB, not in git)
flutter build apk --release       # Android: adb install, am start, adb logcat -s flutter:I
flutter build ios --release --no-codesign
./sign_ios.sh <team wildcard development profile> <identity sha1>   # then xcrun devicectl device install app
```

`sign_ios.sh` signs with a team's Xcode-managed wildcard development profile, so the bench needs no App ID of its own.
