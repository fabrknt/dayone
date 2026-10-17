# Copy for fabrknt.com/hip3/labs/day-one

Source of truth for the Day One page on the HIP-3 site. The page itself is built in `fabrknt/hip3`
(`pages/build.py`, key `"labs/day-one"`); paste the dict below over the existing entry. Same
structure as today: `(title, text)` pairs render as cards, plain strings as paragraphs.
Figures are as of 2026-10-17; update this file first when they change.

```python
    "labs/day-one": {
        "en": {
            "chip": "Fabrknt Labs", "more": ("See HL Price Guard", "price-guard"),
            "title": "Day One — Fabrknt Labs",
            "lead": "Research on making a new HIP-3 listing tradable from its first day without inviting the attacks thin books invite. A reference implementation, not a product.",
            "sections": [
                ("What it studies", [
                    ("Initial liquidity", "A counterparty pool that starts empty, is filled by traders' losses and fees, and is retired once the book is deep enough."),
                    ("Price anomalies", "Fills and liquidations wait whenever HL Price Guard rejects the price: a jump since the last accepted price, a gap to the book, or a gap to an outside reference."),
                    ("Exposure caps", "Opens and closes each have a rolling cap per minute, sized from the book's depth, and net open interest is capped."),
                    ("Who carries the losses", "Losers get pool shares worth 12% of what they lost. Winners leave part of their profit in the pool: 30% on small moves, falling to 15% once the price has moved 1%, as Papertrade does. The rebate is kept below even the lowest haircut, so trading against yourself from two accounts loses money at any size. Rebates are not cut for large losses either: the pool lives only until the book is deep enough, so the dilution has an end."),
                ]),
                ("What it found", [
                    ("Papertrade, 2026-10-10", "Replaying the 228 positions: settling at the oracle instead of the book cut the take by only 15%, because the oracle moved with the push. A per-minute cap of $3.3M would have held it to at most $55K against the $131K the attacker spent."),
                    ("SK Hynix, 2026-07-27", "After the first bad oracle update (-15.6%), the price stepped down 1% at a time. A check against the previous price lets 39 of those updates through; holding the last accepted price lets none through, and pauses for 2 min 12 s."),
                    ("Safe caps", "Measured from the book, the safe settlement rate on a weekend was about $30K a minute for xyz:TSLA and $16K for xyz:SKHX, which then carried $376M of open interest."),
                ]),
                ("How it was checked", [
                    "Five rounds of independent review, the last of which found nothing new. Each finding was first shown with a test that passed only because the flaw existed, then fixed, then the same test was run again.",
                    "The reviews found and closed accounting and share-pricing flaws, among them a way for one trader's open loss to offset another's open profit, ways to take value from earlier shareholders by trading against oneself, and a way to collect shares just before pending orders' fees reached the pool. Shares are now priced at the most the pool can reach from the positions open or requested at the time, and redeemed at a conservative value.",
                ]),
                ("Status", [
                    "Deployed on HyperEVM testnet against xyz:TSLA, with test USDC; not deployed to mainnet, and not audited. It is not offered to traders.",
                    "It uses HL Price Guard pinned to a tagged version (v0.2.1). It moves forward when an operator has a concrete need for it, for example a new or pre-IPO listing whose book will start thin; if that is you, request a readiness review.",
                ]),
            ],
            "labs": True,
        },
        "ja": {
            "chip": "Fabrknt Labs", "more": ("HL Price Guard を見る", "price-guard"),
            "title": "Day One — Fabrknt Labs",
            "lead": "上場したばかりの HIP-3 の銘柄を、板が薄いことにつけこまれずに初日から取引できるようにするための研究です。製品ではなく、参照のための実装です。",
            "sections": [
                ("調べていること", [
                    ("初期の流動性", "空から始まり、トレーダーの損失と手数料で積み上がり、板が十分に厚くなったら役目を終える相手方のプールです。"),
                    ("価格の異常", "HL Price Guard が価格を拒んでいる間は、約定も清算も待たせます。直前に受け入れた価格からの急変、板とのずれ、外部の参照価格とのずれが対象です。"),
                    ("露出の上限", "建てる側と閉じる側のそれぞれに、板の厚さから決めた1分あたりの上限をかけ、差し引きの建玉にも上限をかけます。"),
                    ("損失を誰が負うか", "負けた人には損失の12%に当たる価値のプールの持分を渡します。勝った人は利益の一部をプールに残します。値動きが小さいときは30%、価格が1%動くと15%まで下がります(Papertrade と同じ考え方です)。報酬は最も低い取り分よりも小さく保つので、自分の2つの口座で売り買いすると、どの大きさでも損になります。報酬の発行は大きな損失でも減らしません。プールは板が十分に厚くなるまでの期間限定なので、薄まりにも終わりがあるからです。"),
                ]),
                ("わかったこと", [
                    ("Papertrade(2026-10-10)", "228件の建玉を再現すると、板ではなくオラクルで決済しても抜かれる額は15%しか減りませんでした。押し込みに合わせてオラクルも動いていたためです。1分あたり330万ドルの上限があれば、攻撃側が使った13.1万ドルに対して最大5.5万ドルに抑えられました。"),
                    ("SK Hynix(2026-07-27)", "最初の誤ったオラクル更新(-15.6%)のあと、価格は1%ずつ下がりました。直前の価格とだけ比べる検査はそのうち39回を通してしまいます。最後に受け入れた価格を保ち続ける方式なら1回も通さず、2分12秒止まります。"),
                    ("安全な上限", "板の厚さから測ると、週末の安全な決済の速さは xyz:TSLA で1分あたり約3万ドル、xyz:SKHX で約1.6万ドルでした。そのとき xyz:SKHX には3.76億ドルの建玉がありました。"),
                ]),
                ("どう確かめたか", [
                    "独立したレビューを5回受けました。最後の回では新たな指摘はありませんでした。指摘はまず「欠陥があるときだけ通るテスト」で示し、直したあと同じテストをもう一度流しています。",
                    "会計と持分の値付けの欠陥を見つけて塞ぎました。ある人の含み損が別の人の含み益と相殺されてしまう問題や、自分を相手に売り買いして先にいた持分の保有者から価値を抜ける問題、約定待ちの注文の手数料を当て込んで持分を受け取る問題などです。いまは、持分はその時点の建玉と約定待ちの注文から到達しうる最大の価値で値付けし、払い戻しは控えめな評価で行います。",
                ]),
                ("いまの状態", [
                    "HyperEVM の testnet に、xyz:TSLA を対象としてテスト用の USDC で配置しています。mainnet には配置しておらず、監査も受けていません。トレーダー向けに提供していません。",
                    "HL Price Guard はタグの付いた版(v0.2.1)に固定して使っています。運営者に具体的な必要があるときに進めます。たとえば、板が薄いところから始まる新規上場や pre-IPO の銘柄です。該当する方は運営準備レビューからご連絡ください。",
                ]),
            ],
            "labs": True,
        },
    },
```

## Sources for each figure
- Papertrade replay: `fabrknt/hl-price-guard` cases/papertrade-20261010 (`replay_c.py`, `rounds_vs_binance.py`).
- SK Hynix: cases/skhx-20260727 (`replay_c.py`), `test_jumpLatchOnSkhx`.
- Safe caps: docs/safe-limits.md section 4 (first run, Saturday 2026-10-17; to be re-measured in US hours).
- Review: this repo's README, "Review".
