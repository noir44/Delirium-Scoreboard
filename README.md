# Delirium Scoreboard

Project Zomboid Build 42 mod for the Delirium server: zombie kill boards with
two tabs.

- **Overall**: zombie kills of the player's current character. Death resets it
  to 0: a respawn in Project Zomboid is a brand new character.
- **Event**: kills made since an admin started the current event. A new event
  starts this board from zero, so it can be used to score server events. Death
  resets the player's event score too, unless the sandbox option
  *Death resets the event score* (`DelScore.EventResetOnDeath`) is off.

PvP kills are not counted.

## How kills are counted

The source is vanilla's own counter `player:getZombieKills()`, the "Zombies
killed" line on the character screen. Once per game minute the server reads it
for every online player and adds the growth since the last reading to both
boards. The server watches for deaths and resets the player's row then.

The boards live in global ModData `DelScore` in the world save.

## Admin controls

In the window (button under the left sidebar; players can drag it anywhere,
right click puts it back):

- **New event**: asks for a name, then starts the event board from zero.
- **Stop / Resume**: freezes the event board without clearing it, or
  continues counting.
- Right-click on a row: set a player's value, or remove the player from that
  board.
- **Backups**: list of backups, make one now, restore one.

## Backups

- A backup is made automatically before every admin change (new event, set,
  remove, restore), plus one automatically every game day. The world keeps the
  last 30 manual and the last 24 daily backups.
- Every backup is also written to `Zomboid/Lua/DelScore/backup_NNNN.txt` on
  the server. `Zomboid/Lua/DelScore/current.txt` follows the live boards
  (rewritten at most once a minute).
- **Restore without the game UI** (for example after a world rollback): copy
  any of these files to `Zomboid/Lua/DelScore/restore.txt`. The server loads
  it within 10 seconds, backs up the current state first, then empties
  `restore.txt`.

The file format is plain text: `total<TAB>username<TAB>kills` and
`event<TAB>username<TAB>kills` lines, plus `event_*=` header lines.
