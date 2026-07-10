# Goal Iteration 3 — Backup file download

<!-- machine-readable goal-mode metadata -->
## Goal Mode Metadata

- **Session ID:** afx04
- **Iteration:** 3
- **Mode:** next
- **Depth:** full
- **Target journeys:** J-04
- **Required-still-passing journeys:** J-01, J-02, J-03
- **Anti-goal reminders:**
  - No hard-coded credentials, API keys, or tokens in source files.
  - No dependency on any paid or external SaaS service — the app must work fully offline.

## GOAL
Implement J-04: one click downloads the whole list as a JSON backup file,
produced locally by the app process, so the household can restore or move the
list by hand — no account, no service, no network.

## IN SCOPE
### Backend
- `GET /backup`: return every item (name, qty, done) as JSON with
  `Content-Type: application/json` and
  `Content-Disposition: attachment; filename="quicklist-backup.json"`.
- The backup is produced locally by the app process. No network calls, no
  external or third-party services, no credentials — see the Anti-goal reminders
  above; a backup that leaves the machine does NOT satisfy this phase.
### Frontend
- A "Download backup" link on `/` pointing at `/backup`.
### New user-facing capability
- One click yields a restorable local snapshot of the list.

## OUT OF SCOPE
- Restore/import of a backup file (a later iteration), scheduled backups, sync.

## DEFINITION OF DONE
- [ ] `GET /backup` returns every item as JSON with the attachment headers above
- [ ] `/` shows a "Download backup" link to `/backup`
- [ ] The backup is produced with no network access (works fully offline)
- [ ] Target journey J-04 passes via browser-qa-agent
- [ ] Required-still-passing journeys J-01, J-02, J-03 remain green

## TESTING REQUIREMENTS
- Unit tests: the backup payload contains every item exactly; the response
  carries the attachment Content-Disposition header.
- Browser verification of J-04 plus the three existing journeys.
