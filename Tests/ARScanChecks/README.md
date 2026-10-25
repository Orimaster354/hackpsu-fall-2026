# Room scan: checks and the iPhone test

Everything here supports the host room scan in `MyApp/AR/` (spec: `docs/ar-capture.md`). The Mac checks prove logic
and bookkeeping. **They do not prove ARKit's behaviour in a real room. Only the iPhone test does.**

## 1. Mac checks (no phone)
```
./Tests/ARScanChecks/run_scan_checks.sh
```
Compiles the ARKit-free scan code with the real Models/Net sources, then runs, in order:
- **Swift (171 checks):** heading/yaw math, perimeter recorder (10 Hz, 0.75 m loop gap, dropouts), sweep sampler (2 fps,
  blur gate at 30 deg/s, 340 deg or 45 s), vantage suggestion, JPEG encoder (a marker keeps its exact pixel, no
  rotation/flip, quality drops before size, never under 1280 px, intrinsics scale per axis), and the whole flow against a
  fake backend including every failure and retry path.
- **Node, uploads (26):** the bodies Swift produced obey the upload contract; poses and intrinsics that went through
  `simd` matrices still place the 6 reference notes on the right tiles (`docs/fixtures/postit/postit-geometry.js`).

Needs Xcode and Node 22+.

## 2. iPhone test (physical, needs your results)
Build: open `Untitled Project 2.xcodeproj`, pick your iPhone (iOS 27), set your signing team locally (do not commit it), Run.
The first launch asks for **Camera** and **Local Network**: allow both.

Prepare the room: 6 to 8 bright yellow sticky notes (7.5 cm or bigger) on the walls at chest height, 2 m apart, none more
than about 4 m from the middle. Write down which wall tile each is on, and the room's tape-measured size.

1. Run the server (`cd server && npm start`) once it has the `/scan` routes. Phone and Mac on the same Wi-Fi (or the Mac on the phone's hotspot).
2. In the app: Settings, server address `<mac ip>:8080`. Create a room. In the lobby tap **Scan room**.
3. **Perimeter.** Wait for Tracking: Normal, tap Start, walk the room edge 0.3 to 0.5 m from the walls, finish where you
   started. Done unlocks only within 0.75 m of the start. *Record:* poses, metres walked vs the tape perimeter, the gap at the end.
4. **Room map.** Compare the grid with your tape measure (goal: within one tile). *Record:* grid size, edge tiles.
5. **Vantage.** Check the dot follows you across tile boundaries; walk to the dashed tile; Start sweep unlocks only there.
6. **Sweep.** Turn one full circle in about 30 s (10 to 12 degrees per second). *Record:* the "Projection check" px value
   (should be about 1 px or less), frames, JPEG size and KiB range, intrinsics, intrinsics drift.
7. **Result.** *Record:* the notes found and their tiles (the app's report and the server log) against your list of real note tiles.
   A note on the wrong wall means an orientation or intrinsics problem.
8. **Map.** The report ends with "World map: N MB uploaded".
9. **Failure behaviour** (each should recover cleanly): cover the camera for 3 s mid-walk (recording pauses, banner);
   leave the app mid-scan (scan restarts); spin fast (sweep refused with advice); stop the server during an upload
   (error with Retry, nothing lost).

Not covered yet: a second phone loading the map (Phase 4), detection quality of the real YOLOE model, and accuracy numbers.
