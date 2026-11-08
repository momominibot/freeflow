# Read-aloud test script (30 sentences)

Purpose: a test set in your own voice, with the right answer known, to compare the speech engines on English plus Chinese.

## How to record

1. FreeFlow menu: **Speech engine › Keep my recordings on this Mac** (tick it), and **Language › English + Chinese (mixed)**.
2. Delete any older saved recordings first (Speech engine › Delete saved recordings) so only these 30 are in the folder.
3. Go in order, one sentence per recording: tap Fn, read the sentence the way you would really say it, tap Fn. Paste doesn't matter, any text box works.
4. Speak naturally, with your usual speed and accent. If you stumble, carry on and read it again as a normal recording at the end; don't skip numbers.
5. When all 30 are done, run:

```bash
~/Library/Application\ Support/FreeFlow/engines/qwen/venv/bin/python ~/Desktop/_Projects/freeflow/scripts/compare-engines.py \
  --script ~/Desktop/_Projects/freeflow/docs/read-aloud-script.txt -o ~/Desktop/engine-report.md
```

The report lists, for every sentence, what Whisper and Qwen heard next to what you read, and the word error for each engine (Chinese counted per character).

## A. Chinese and English in one sentence

1. 我们明天要 send the invoice 给 Ranklore，然后 update 一下 Shopify 的 theme。
2. 这个 quote 帮我 follow up，客户说 budget 有点 tight。
3. 下午三点的 meeting 改到四点，记得 book 会议室。
4. 请你帮我 check 一下 Wellness Protocol 的 reviews，看看有没有 bad feedback。
5. 今天的 hacking works 要先 notify neighbours，不然 HDB 会罚款。
6. 我现在在 MRT 上，到了公司再 call 你。
7. 这个 bug 我昨天已经 fix 了，你 refresh 一下页面看看。
8. 老板说这个星期五之前一定要 submit，所以今天要 rush 一下。
9. 你可以 send 我那个 PDF 吗？我晚上再 review。
10. 周末我们去 hawker centre 吃饭，你想吃 chicken rice 还是 laksa？
11. 客人想要 refund，但是已经超过 fourteen days 了，怎么办？
12. 这个 landing page 的 headline 太长了，改短一点，要 punchy 一点。

## B. Singapore English

13. Can you help me check the quote first, then we decide lah.
14. Aiyo, the client changed the brief again, so we need to redo everything.
15. I already told him the deadline is Friday, but he still never reply leh.
16. This one very simple only, just copy the file and paste into the folder.
17. Wah, the hacking works today damn noisy, I cannot concentrate.
18. Later we go makan first, then come back to finish the proposal, can?
19. Don't worry, I will follow up with the contractor and update you by tomorrow.
20. Eh, the Wellness Protocol page loading quite slow, you help me look see look see.

## C. Plain English with your work words

21. Please commit the change, not commute, and push it to the main branch after the tests pass.
22. Send the Ranklore proposal to the client by Thursday and copy the finance team.
23. We should keep the budget tight and review it again in January.
24. Update the Supabase policy, redeploy to Vercel, and then check the Shopify checkout again.
25. The meeting is at noon, so please book the small room upstairs.
26. Remind me to renew the domain before the end of the month.

## D. Chinese only

27. 明天下午三点开会，记得带电脑和充电器。
28. 这个星期的销售报告我已经发给你了，请查收。
29. 我觉得这个方案可以，不过价格还要再谈一谈。
30. 麻烦你把客户的资料整理一下，今天下班前发给我。

Notes: say the English words in English ("send", "invoice"), not translated. In sentence 11 say "fourteen days" in words. The names Ranklore, Wellness Protocol, Supabase, Vercel and Shopify are in your dictionary.
