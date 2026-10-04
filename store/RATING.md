# Hollowmere: age rating notes

Prepared answers for the rating questionnaires (IARC for web, itch.io and the Microsoft Store, which also issues PEGI and USK; the Steam content survey). Fill them in exactly like this and check the result against the expectations below before every store submission. Re-run the questionnaire whenever the casino, chat or purchases change.

## What the game contains

| Topic | Answer | Where |
|---|---|---|
| Violence | Fantasy creatures battle turn-based; they faint, no blood, no death. | Battles |
| Simulated gambling | **Yes.** An interactive casino: roulette, blackjack, slot machines, video poker, betting on creature races and a free daily prize wheel. Players stake chips and win or lose them by chance. | Lumière, Grand Casino |
| Real-money gambling | No. Chips are bought only with in-game gold (10 gold per chip) and sold back at the same rate. Nothing can be bought with real money and nothing can be paid out. | Cashier |
| In-game purchases | None. The game is free and has no shop for real money, no loot boxes and no ads. | – |
| User interaction | Yes: online co-op with friends (invite code), free-text chat between the players of one farm, no public lobbies. | Co-op |
| Shares location | No. | – |
| Personal data | Account (email or Google sign-in) for cloud saves; crash reports on by default, play stats only after opt-in. | Settings, Privacy |
| Alcohol, drugs, tobacco | No. The casino bar serves tea, cake and pudding. | – |
| Sexual content, nudity | No. Villagers can be courted and married (hand-holding level). | Town |
| Language | No strong language. | – |

## Expected results

The casino decides the rating. Since 22 September 2024 Australia classifies every game with **simulated gambling as R 18+**, no matter how small the part or which currency is staked, and the IARC tool generates matching ratings. Other systems differ:

| System | Expected | Note |
|---|---|---|
| IARC generic | 18+ (Simulated Gambling) | Shown by stores without their own system. |
| Australia (ACB) | R 18+ (High-impact simulated gambling) | Legally restricted to adults. |
| PEGI | 12 to 18 (Gambling) | Comparable casino-style titles received PEGI 18. |
| USK | 12 to 16 (Simuliertes Glücksspiel / Glücksspielthematik) | The USK lists simulated gambling as a risk factor. |
| ESRB | T (Simulated Gambling) | E10+ is possible if the questionnaire only finds gambling themes. |
| Steam | Mark "Frequent violence or gore": no; "General mature content": no; add the note "Contains simulated gambling with play money (no real-money purchases or payouts)". | Steam asks for a short description. |

Without the casino the game would be rated about 7+ (PEGI 7, USK 6, ESRB E10+ for fantasy violence).

## Options if the rating is a problem

1. **Keep the casino** (current plan). Accept 18+ in Australia and possibly PEGI 18, and say so plainly on the store pages.
2. **All-ages edition.** Export with the feature tag `no_casino` (add it under Export > Features > Custom in the preset). The casino doors stay shut, its settings and quests disappear, and Lumière remains as a seaside town. Rate that build separately. The web build can only have one variant, so this fits a second store listing, for example a console or kids' edition.
3. **No stakes.** Rework the games so nothing is staked (free play for fun, prizes only from the daily wheel). That usually drops the content to "gambling themes" (USK 12, ESRB E10+, Australia M) but changes the design that was decided for Phase I.

## In-game safeguards (already built)

- First visit to the casino: a notice that chips are play money, cannot be bought with real money and cannot be paid out.
- Signs at the casino entrance and inside the hall repeat it; every casino window has a footer saying so.
- Settings: a daily stake limit (off by default) and "Hide the casino", which closes it and hides its quests.
- Exact odds: the rules of every game list the payouts; slot RTP about 95 %, verified in CI with a 1 million round simulation.
