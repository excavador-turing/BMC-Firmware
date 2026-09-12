---
name: Something is wrong
about: The board did something it should not have, or did not do something it should
title: ""
labels: bug
---

<!-- Read https://turingpi.xyz/reference/known-faults/ first. If it is listed
     there, it already has a ticket; a comment on that entry beats a new issue. -->

**What happened, and what you expected instead**


**Which board and which firmware** — paste the output of these two, run on the BMC:

```
$ tpi about
$ cat /etc/os-release | grep VERSION
```

Board revision matters: stock firmware reports v2.5.1 for a v2.5.2 board, so the
answer *after* installing this fork is the one to trust.

**How you reached the board** — its own page directly, the fleet interface, `tpi`,
or the API. A browser bug and a daemon bug look alike from the outside and are
not.

**What the board says about it** — anything relevant from:

```
$ ls -t /var/log/bmcd.*.log | head -1 | xargs tail -50
$ cat /mnt/overlay/postupdate.log        # if this is about an upgrade
```

`/var/log` is a tmpfs and does not survive a reboot; `/mnt/overlay` does.

**Anything else** — screenshots, a console recording, what changed just before.
