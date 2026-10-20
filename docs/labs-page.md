# Copy for fabrknt.com/hip3/labs/day-one

Source of truth for the Day One page on the HIP-3 site. The page itself is built in `fabrknt/hip3`
(`pages/build.py`, key `"labs/day-one"`); paste the dict below over the existing entry. Same
structure as today: `(title, text)` pairs render as cards, plain strings as paragraphs.
Figures are as of 2026-10-21 (backing check, graduation criteria, halted markets and review count changed on 10-19 to 10-21) and follow hl-price-guard 1f8ff12; update this file first when they change.
The hip3 site no longer takes this dict as is (the C5 design, 2026-10-18); the hip3 window ports it by hand,
so keep the meaning of each sentence stable.
No contract addresses in this copy (founder, 10-18): the testnet operator was funded from the
founder's earlier deployer address, so the pool links to it on chain. Add the pool address only
after a redeploy from a key funded with no link to the founder.

```python
    "labs/day-one": {
        "en": {
            "chip": "Fabrknt Labs", "more": ("See HL Price Guard", "price-guard"),
            "title": "Day One — Fabrknt Labs",
            "lead": "Research on making a new HIP-3 listing tradable from its first day without inviting the attacks thin books invite. A reference implementation, not a product.",
            "sections": [
                ("What it studies", [
                    ("Initial liquidity", "A counterparty pool that starts from a small seed from the market's operator, grows with traders' losses and fees, and is retired once the book is deep enough: spread, depth and HL open interest past set levels for ten trading days in a row, or a fixed deadline, whichever comes first."),
                    ("Backing", "A new position is taken only if, after a 10% move either way, the pool could still pay every winner from its balance, without counting on other traders' future losses. While any winner is waiting to be paid, no new positions open."),
                    ("Price anomalies", "Fills and liquidations wait whenever HL Price Guard rejects the price: a jump since the last accepted price, a gap to the book, or a gap to an outside reference."),
                    ("Exposure caps", "Opens and closes each have a rolling cap per minute, sized from the book's depth, and net open interest is capped."),
                    ("A halted market", "When the market is halted or delisted, its book is empty and every price read is refused. Once the book has stayed empty and the oracle unchanged for an hour, closes, liquidations and redemptions settle at that oracle; the operator can also end the pool at the oracle, a day after announcing it. Hyperliquid settles a halted market at its oracle, as Paragon did with para:PAPER on 2026-10-19."),
                    ("Who carries the losses", "Losers get pool shares worth 12% of what they lost. Winners leave part of their profit in the pool: 30% on small moves, falling to 15% once the price has moved 1%, as Papertrade does. The rebate is kept below even the lowest haircut, so trading against yourself from two accounts loses money at any size. Rebates are not cut for large losses either: the pool lives only until the book is deep enough, so the dilution has an end."),
                ]),
                ("What it found", [
                    ("Papertrade, 2026-10-10", "Replaying the 228 positions: settling at the oracle instead of the book cut the take by only 15%, because the oracle moved with the push. An exposure cap of $3.3M per minute would have cut the take to an estimated $55K, below the $130,873 the push cost (assuming the incident's average edge and pushes that cost what Papertrade's did; an estimate, not a bound)."),
                    ("Papertrade's straddle, 2026-10-20", "Papertrade said a trader could push its pool insolvent by closing only the winning side of a straddle, then collect rebate tokens at a flat rate. Replayed on Day One, booking the win first can hand the losing side up to 99% of the shares, but they are priced at the pool's value net of what winners are owed, so after the operator seeds again they are worth exactly the rebate: the straddle still loses money."),
                    ("SK Hynix, 2026-07-27", "After the first bad oracle update (-15.6%), the price stepped down 1% at a time. A check against the previous price lets 39 of those updates through; holding the last accepted price lets none through, and pauses for 2 min 12 s."),
                    ("Safe caps", "Measured from the book on Friday 2026-10-16 after the US close (UTC), the safe settlement rate was about $30K a minute for xyz:TSLA and $16K for xyz:SKHX, which then carried $376M of open interest. A full US session is still to be measured."),
                ]),
                ("How it was checked", [
                    "Thirteen rounds of independent review, with follow-ups, of the contract, the keeper, its installer and the page; the last rounds on the contract and the page found nothing new. Each finding was first shown with a test that passed only because the flaw existed, then fixed, then the same test was run again.",
                    "The reviews found and closed accounting and share-pricing flaws, among them a way for one trader's open loss to offset another's open profit, ways to take value from earlier shareholders by trading against oneself, a way to collect shares just before pending orders' fees reached the pool, a way to pair an old haircut with a newer, higher rebate across a parameter change, a backing check in which one position's loss beyond its margin could offset another's profit, and a stress size the operator could set to zero. Shares are now priced at the most the pool can reach from the positions open or requested at the time, and redeemed at a conservative value.",
                ]),
                ("Status", [
                    "Deployed on HyperEVM testnet against xyz:TSLA, with test USDC; that deployment predates the backing check, which is tested locally and awaits a redeploy. Not deployed to mainnet, and not audited. It is not offered to traders.",
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
                    ("初期の流動性", "市場の運営者の少ない初期資金から始まり、トレーダーの損失と手数料で積み上がる相手方のプールです。板が十分に厚くなったら役目を終えます。スプレッド・板の厚さ・HL 側の建玉が決めた水準を10取引日続けて超えるか、あらかじめ決めた期限が来るか、早いほうで終わります。"),
                    ("裏付け", "新しい建玉は、価格が上下に10%動いてもプールの残高で勝った人全員に払える場合にだけ受けます。他のトレーダーの将来の損失はあてにしません。支払いを待っている勝者が1人でもいる間は、新しい建玉を受けません。"),
                    ("価格の異常", "HL Price Guard が価格を拒んでいる間は、約定も清算も待たせます。直前に受け入れた価格からの急変、板とのずれ、外部の参照価格とのずれが対象です。"),
                    ("露出の上限", "建てる側と閉じる側のそれぞれに、板の厚さから決めた1分あたりの上限をかけ、差し引きの建玉にも上限をかけます。"),
                    ("銘柄の停止", "銘柄が停止または上場廃止されると板が空になり、価格の読み取りはすべて拒まれます。板が空で oracle が動かないまま1時間たてば、決済・清算・払い戻しをその oracle で受けます。運営者は、予告から1日たてば oracle の価格でプールを終えることもできます。Hyperliquid は停止した銘柄を oracle で決済します(2026-10-19 に Paragon が para:PAPER をそうしました)。"),
                    ("損失を誰が負うか", "負けた人には損失の12%に当たる価値のプールの持分を渡します。勝った人は利益の一部をプールに残します。値動きが小さいときは30%、価格が1%動くと15%まで下がります(Papertrade と同じ考え方です)。報酬は最も低い取り分よりも小さく保つので、自分の2つの口座で売り買いすると、どの大きさでも損になります。報酬の発行は大きな損失でも減らしません。プールは板が十分に厚くなるまでの期間限定なので、薄まりにも終わりがあるからです。"),
                ]),
                ("わかったこと", [
                    ("Papertrade(2026-10-10)", "228件の建玉を再現すると、板ではなくオラクルで決済しても抜かれる額は15%しか減りませんでした。押し込みに合わせてオラクルも動いていたためです。1分あたり $3.3M の露出上限なら、得られる額は約 $55K と見積もられ、押し込みにかかった $130,873 を下回ります(事故時の平均的な取り分を当てはめ、押し込みのコストが Papertrade と同じだと仮定した推定で、上限の保証ではありません)。"),
                    ("Papertrade の両建て(2026-10-20)", "Papertrade は、両建ての勝ち側だけを閉じてプールを支払い不能に押し込み、負け側で報酬のトークンを定額で受け取る攻撃を挙げました。Day One で再現すると、勝ちを先に計上すれば負け側が持分の最大99%を得ます。ただし持分は勝者への未払いを引いたプールの価値で値付けされるので、運営者が初期資金を入れ直したあとの価値はちょうど報酬の額で、両建ては損のままです。"),
                    ("SK Hynix(2026-07-27)", "最初の誤ったオラクル更新(-15.6%)のあと、価格は1%ずつ下がりました。直前の価格とだけ比べる検査はそのうち39回を通してしまいます。最後に受け入れた価格を保ち続ける方式なら1回も通さず、2分12秒止まります。"),
                    ("安全な上限", "2026-10-16(金)の米国の取引終了後(UTC)に板の厚さから測ると、安全な決済の速さは xyz:TSLA で1分あたり約3万ドル、xyz:SKHX で約1.6万ドルでした。そのとき xyz:SKHX には3.76億ドルの建玉がありました。米国の取引時間を通した計測はまだです。"),
                ]),
                ("どう確かめたか", [
                    "コントラクト・keeper・導入スクリプト・画面は、独立したレビューを13回(それぞれの再確認を除く)受けました。コントラクトと画面の最後の回では、新たな指摘はありませんでした。指摘はまず「欠陥があるときだけ通るテスト」で示し、直したあと同じテストをもう一度流しています。",
                    "会計と持分の値付けの欠陥を見つけて塞ぎました。ある人の含み損が別の人の含み益と相殺されてしまう問題や、自分を相手に売り買いして先にいた持分の保有者から価値を抜ける問題、約定待ちの注文の手数料を当て込んで持分を受け取る問題、パラメータ変更をまたいで古い取り分と新しい高い報酬を組み合わせる問題、裏付けの検査で、証拠金を超えた損失が別の人の利益を打ち消してしまう問題、運営者が想定する値動きの幅を0にできた問題などです。いまは、持分はその時点の建玉と約定待ちの注文から到達しうる最大の価値で値付けし、払い戻しは控えめな評価で行います。",
                ]),
                ("いまの状態", [
                    "HyperEVM の testnet に、xyz:TSLA を対象としてテスト用の USDC で配置しています。この配置は裏付けの検査より前の版で、検査はローカルで確かめ、配置し直しを待っています。mainnet には配置しておらず、監査も受けていません。トレーダー向けに提供していません。",
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
- Halted market: docs/design.md (10-20), README review round 13; mainnet facts in hip3-ops docs/verification/2026-10-20-para-paper-halt.md.
- Straddle replay: test_straddleRebateWorthOnlyTheRebate and its fuzz twin (99.35% of shares at an end price of $414.44, worth $540 = the rebate).
- Papertrade cap figure: docs/safe-limits.md (hl-price-guard 1f8ff12): $55,101 at $3.3M/min over the 18 closing minutes, against $130,873 spent; a scenario estimate, not a bound.
- Safe caps: docs/safe-limits.md section 4 (first run, Friday 2026-10-16 after the US close, UTC; a full US session, 2026-10-19, is scheduled).
- Review: this repo's README, "Review".
