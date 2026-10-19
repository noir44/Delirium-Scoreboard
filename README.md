# Delirium Scoreboard

Project Zomboid Build 42 mod for the Delirium server: zombie kill boards with
two tabs.

- **Overall**: vanilla's own counter of the player's current character (the
  "Zombies killed" line of the character screen, the server's copy). A respawn
  in Project Zomboid is a brand new character, so death resets it.
- **Event**: kills made since an admin started the current event. A new event
  starts this board from zero, so it can be used to score server events. Death
  resets the player's event score too, unless the sandbox option
  *Death resets the event score* (`DelScore.EventResetOnDeath`) is off.

PvP kills are not counted.

## How kills are counted

- **Overall** copies `player:getZombieKills()` of every online player twice a
  second. Offline players keep their last value.
- **Event** counts every zombie death the server processes (`OnZombieDead`),
  credited to the player in `zombie:getAttackedBy()`.

The two can differ: on a dedicated server the vanilla counter misses some
kills (the engine raises it only on some of the ways a zombie dies; a test
gave 15 on the counter for 20 zombies killed). The event board is the exact
one.

The boards are kept in files on the server, `Zomboid/Lua/DelScore/`, written
within seconds of every change - not in the world save, so a server closed
without saving (console window closed) loses nothing.

## Admin controls

In the window (button under the left sidebar; players can drag it anywhere,
right click puts it back):

- **New event**: asks for a name, then starts the event board from zero.
- **Stop / Resume**: freezes the event board without clearing it, or
  continues counting.
- Right-click on a row: set a player's value, or remove the player from that
  board. On the overall board, setting a value changes the character's own
  counter, so the player must be online and alive.
- **Backups**: list of backups, make one now, restore one.

## Files and backups

All in `Zomboid/Lua/DelScore/` on the server:

- `state_a.txt`, `state_b.txt`: the live state, written in turn within 2
  seconds of a change. On start the server loads the newer complete one, so a
  crash in the middle of a write still leaves the other file.
- `backup_NNNN.txt`: a backup is made before every admin change (new event,
  set, remove, restore), on every server start and every game day. The
  admin window lists the last 30 manual and 24 automatic ones; older files
  stay on disk.
- `backups.txt`: index of the listed backups.
- **Restore without the game UI**: copy any backup or state file to
  `restore.txt`. The server loads it within 10 seconds, backs up the current
  state first, then empties `restore.txt`.

The file format is plain text: `total<TAB>username<TAB>kills` and
`event<TAB>username<TAB>kills` lines, plus `event_*=` header lines.

If the world itself is rolled back (server stopped without saving), the
boards keep the kills they already had; a character whose counter came back
lower continues counting from there.
