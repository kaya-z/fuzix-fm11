# FUZIX FM-11 ステージ2: MMU モード設計 (案)

## 根拠 (FM-7,11 Application note p.227-229 / MK09 kernel.s memprobe)
- MMR `$FD80-$FD8F`: 論理 4KB ページ i -> 物理ページ番号 (A19-A12)。マップセットは `$FD90` 下位4bit (16 セット)。
- 論理 `$FC00-$FFFF` は MMR の対象外 (固定)。`$FD8F` が効くのは `$F000-$FBFF`。
- `$FD93` bit7 = MMR 有効 / bit6 = 窓 (`$7C00-$7FFF`、`$FD91`/`$FD92`) / bit0 = ブートROM。
- MSG はリセットで 0、MMR の中身は不定 -> 有効化前に全セット初期化が必要。
- 主記憶は 128KB 単位で最大 1MB。MK09 の `memprobe` は窓越しに `$A5 $5A` を書き読みし、下位ミラーを除外して判定 (未実装域の見え方は実機未確認)。

## 方針: coco3 型 (カーネル用マップ + ユーザ用マップ)
- 使うセットは 2 つだけ: set 0 = カーネル、set 1 = 現在のユーザプロセス。
  プロセス切替のたびに set 1 の MMR 16 個を書き換える (セット数の上限 15 を避ける)。
- set 0 は恒等写像。現在のフラット配置 (text 0600-6E97、data E300-F9BD) をほぼそのまま使える。
- set 1: 論理 0000-EFFF = プロセスのページ (最大 60KB)、論理 F000-FBFF = 共通ページ (set 0 と同じ物理ページ)。
- 共通ページ (F000-FBFF) に置くもの: マップ切替・syscall/IRQ 入口・udata・割り込みベクタのジャンプテーブル (今は `$0100` で、ユーザ領域になるので移す)。
- カーネルからユーザ空間へのアクセス (uget/uput/uzero): set 0 の空き論理ページ (`$7000-$DFFF`) に
  ユーザの該当ページを窓として写し、通常のブロックコピーで転送 (最大 3 ページ = MMR 書込み 3 回)。
- メモリ管理: `bank8k.c` を 4KB ページ版 (`bank4k.c`) に改造。プロセスごとにページ表 16 エントリ、必要ページ数だけ確保。
  プール = 物理ページ 7-13 (カーネルが使わない `$7000-$DFFF`) + 16 以降の検出された全ページ。
  空きが足りなければ従来のスワップ (SWAPDEV) に落とす。
- 搭載メモリ自動検出: 128KB 単位で窓から試し書き、ミラー除外。結果を `ramsize` とプールに反映。

## 段階
1. memprobe + MMR 初期化 (エミュレータ `--mem 128/256/1024` で確認)
2. bank4k.c + map_* + usermem + fork コピー + 共通ページ分離
3. 起動、`ls`/`cp`/複数プロセスの確認、メモリ量別テスト
4. 実機 (HFE) 確認。未実装域の読み出し挙動と `$FD57` のパリティ NMI を要確認


## Result of stage 2a (2026-11-21)
Implemented as designed (coco3-style two maps, `bank4k.c`, window A/B for user memory and fork copies), see `fuzix-fm11mmu/README.md`.
Bugs found on the way: `map_proc_always` left the saved A on the stack (return address off by one byte);
`memprobe` did not put the test pattern back, so every machine looked like 256KB; `.bss` overlapped `.text2`;
the pool stack was fine (the earlier "row[0]=0" came from the compiler's `ptr[i] = pfree[--pfptr]`, replaced by `getpage()`).
Pool of a 128KB machine: 20 pages, too small for init + shell + a fork of the shell: needs swap or shared text pages (stage 3).

## Stage 2b: text sharing (2026-11-21)
`fork` shares the text-only pages (1..`(PROGLOAD+a_text)>>12`-1) with the child (`pgref`, `pshare` in `bank4k.c`).  128KB: login, sh, ps work;
`ls` still needs 2 pages more than the pool has.  Also fixed: `a_size` counts from `a_base`, so the process top was one page too high.

## Stage 2c: the last program page is the udata page (2026-11-21)
exec sets top = P*4096-$200; logical page P-1 and logical page 14 map the same physical page (the 3.5KB below udata are program memory).
Saves a page per process; 128KB now runs login, sh, ls, ps.  `copy_pages` skips the duplicate entry; `pagemap_free/realloc` know the alias.

## ステージ2d: スワップ (2026-11-21)

`ls` / `ps` より大きいプログラムが入らないとき、待機中のプロセスをディスクへ追い出す。

- 汎用 `swap.c` を使用 (`CONFIG_DYNAMIC_SWAP`: ドライブ1のタイプ 0x7F パーティションを起動時に検出, `SWAP_SIZE` 0x78 = 120ブロック/プロセス)。
  fd1 のスワップ領域は 1920 ブロック (`mkfd.py -s 1920`) = 16 プロセス分 (`MAX_SWAPS`)。
- `bank4k.c`: `makeroom(n)` が fork (`pagemap_alloc`) と exec (`pagemap_realloc`) の前に空きページが n 枚になるまで `swapneeded()` で
  最も長く待っているプロセスを追い出す。`swapout()` はプロセスの全ページ (+ udata ページ) を 4KB ずつ書き、`pagemap_free()` で解放して `p_page=0`。
- 書き戻しは `tricks.s` の `_switchin` が `p_page==0` を見つけたとき `fm11_swapin()` を呼ぶ。専用スタック (`swstack` 512B) 上で実行
  (旧プロセスのスタック=その udata ページが新プロセスに割り当てられうるため)。戻したページは全て private (テキスト共有は解消)。
- `devhd.c`: swap (`td_raw==2`) は物理ページ番号 `td_page` に対して DMA する (`DMA_BANK` = 物理アドレス bit19-16) ので、マップ不要。
- init の udata ページ (物理 14, 起動ページ) はプールに戻さない。
- カーネルが 0x9000 台に入ったためページ 9 はプールに加えない (プールはもともとページ 10-13 と 16 以上: 128KB 機で 20 ページ = 80KB)。
- 確認: 128KB で `cat /dev/zero >/dev/null &` を4つ起動して `ps` → init / sh が出入りしつつ動作継続。256KB/1MB はスワップ不要で従来通り。
- 注意: `OFTSIZE` が 15 のため、cat 5 つ以上で open が失敗する (スワップとは無関係)。実機 (HFE) は未確認。
- 実機修正 (2026-11-21): `mkimage.py` が全部 0 の区間を省いていたため、実機では udata ($EE00-) などがゴミのまま → `u_euid`≠0 で rc の `remount` が EPERM。全区間を書くよう修正 (カーネル 145 セクタ)。
- ドライブ1台構成: FlashFloppy は1台の Gotek で2台分のイメージを扱えない (DS0/DS1 両方にジャンパを入れると同じイメージで両方に応答し、hdb = hda に見える)。
  `mkfd.py -S 480` でドライブ0のルートの後ろにスワップ区画 (タイプ 0x7F, 4 プロセス分) を置く。ルートは 1400 ブロックに縮小。起動ログは `hda: hda1 hda2 (swap)`。
- ルートに `od` を追加 (Applications/util/fuzix-util.pkg の util-mini に `/bin/od`)。
- `reboot` が効かない件 (2026-11-22): 標準の `/etc/rc.reboot` の最終行が `reboot` で、init に再度レベル5を頼むだけだった。`reboot -f` に修正 (etc-files/rc.reboot)。`shutdown` は `Halted.` で停止する (電源は切れない)。
