# Chrome Remote Debugging Notes

## Current Chrome behavior

Chrome 136+ no longer respects `--remote-debugging-port` or
`--remote-debugging-pipe` for the default Chrome data directory. A non-standard
`--user-data-dir` is required. The normal logged-in browsing profile therefore
cannot be monitored through CDP just by restarting Chrome with port 9222.

Expected symptom:

- Chrome process command line contains `--remote-debugging-port=9222`.
- No listener appears on `127.0.0.1:9222`.
- `curl http://127.0.0.1:9222/json/version` fails.

## Practical options

- Real profile, no new profile: use Chrome Task Manager for PID-to-tab labels.
- Automation profile: start Chrome with
  `--remote-debugging-port=9222 --user-data-dir=/path/to/non-default-dir`.
- Chrome for Testing: acceptable for automation, not for the user's logged-in
  daily tabs unless they deliberately use that profile.

## Sources to cite when needed

- Chrome Developers Blog, "Changes to remote debugging switches to improve
  security", 2025-03-17.
- Chrome DevTools Protocol `SystemInfo.getProcessInfo` for process listings when
  CDP is actually reachable.
