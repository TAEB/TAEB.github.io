---
title: Solving NetHack's Mastermind
layout: default
---
Note: This article was originally written in 2006. It is published here for posterity.

NetHack's Mastermind is very similar to the real Mastermind, with three changes:

* Instead of five colors, there are seven notes (A, B, C, D, E, F, and G).
* There are five positions, not four.
* You can give partial solutions (such as AB even though the solution is five notes long).

A gear represents a note in the correct position. A tumbler represents a note in an incorrect position. So, for example, if you're trying to find the tune FFAAB and you guess AFAFB, you'll get three gears and two tumblers. If you guess CA you'll get one tumbler. If you guess BBBBB you'll get one gear. If you guess DDDDD you'll get silence (in other words, no gears and no tumblers).

This document describes my attempts at optimizing a NetHack Mastermind solver (with help from Sean Kelly and papers from Don Knuth and Barteld Kooi). The first, naïve algorithm finds the solution on average within 15 turns, possibly taking up to 21. The last, most effective algorithm finds the solution on average within 4 turns, possibly taking up to only 6. This is an important result because in NetHack, the level where you play Mastermind is one of the most dangerous, so you have a strong incentive (your own survival) to find the solution as quickly as possible.
