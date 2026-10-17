# Manual validation — 1.0.0

Run `rtk proxy zsh scripts/run-validation.sh` from the repository root. This starts
the candidate in `dist` with a separate library in ignored `work/manual-validation`
and a separate preferences suite. The installed app and normal library are not
replaced. Accurate mode may download its runtime and weights on first use in this
isolated library. Quit an existing candidate before opening it again.

1. Open `examples/two-speakers-demo.mp4`. Check video, play/pause, mute, volume,
   seeking, follow playback and the layout of menus and model badges.
2. Run Fast with an explicitly selected Parakeet model, then Accurate with Qwen.
   Check progress, completion, two voice labels where supported, and review flags.
   Recognition may differ by model; compare against the included reference SRT.
3. Edit text, rename a speaker, reassign a segment, confirm reviews, remove a
   speaker and Undo. Quit and reopen the candidate; verify the saved edits remain.
4. Export TXT, Markdown, JSON, SRT and VTT. Open the files and check non-English
   text, names, timing and Markdown escaping. Try quick export twice beside a
   copied demo; the second export must get a new filename without overwriting.
5. Start processing, press Stop, then run again. Check that Stop does not replace
   an existing transcript with partial output and that controls become available.
6. Using synthetic media with separate container tracks, check Separate audio and
   One speaker per audio track. Source labels must remain distinct; track start
   offsets must align with playback. A total speaker count must not force mixing.
7. Test a missing or unreadable source and a read-only export destination. The app
   should show an error while retaining an existing editable transcript.
8. Clear only the isolated test library. Cancel first, then confirm; reopen the
   candidate and verify the test library stays empty.

Do not clear the normal library or commit any recordings/transcripts from manual
checks. Record results before approving a release. Automated tests do not replace
this GUI check, a real speech quality review, or testing on macOS 14.
