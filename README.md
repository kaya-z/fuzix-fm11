# FUZIX for the FUJITSU FM-11 / FUJITSU FM-11 向け FUZIX

[日本語](#日本語) | [English](#english)

---

## English

A port of [FUZIX](https://github.com/EtchedPixels/FUZIX) (a UNIX-like OS by Alan Cox and contributors) to the **FUJITSU FM-11** (Motorola MC6809, 2HD floppies, 128KB–1MB RAM, MMU).

There are two ports in this repository:

| Directory | Stage | What it is |
|---|---|---|
| `fuzix-fm11/` | 1 | MMU off, 64KB flat, one process in memory, swap only. Derived from the `platform-sim09` of FUZIX. |
| `fuzix-fm11mmu/` | 2 | **MMU on**: 4KB pages, several processes in RAM, **installed memory detected automatically and all of it used** (128KB–1MB), text sharing on `fork`, swap to disk. |

Use stage 2 (`fuzix-fm11mmu`) unless you have a reason not to.

### Status

* Boots to the login prompt in the Fm11gtk emulator with 128 / 256 / 384 / 640 / 1024KB. `root` (empty password) gets a shell; `ls`, `ps`, `cat`, `dd`, `od`, `mount`, `reboot` etc. work.
* Reported running on a real FM-11 with 896KB (the banner shows `896K RAM (MMU on), 848K for processes`). Real-hardware testing is still in progress: the swap partition on a second drive, the behaviour of unmapped memory reads and the parity NMI (`$FD57`) are **not verified on a real machine**.
* `shutdown` / `halt` stop the machine (`Halted.`); the FM-11 cannot be switched off by software.
* `login` prints `unable to change owner of controlling tty` (harmless so far).

### Features of stage 2

* **MMU** (`$FD80–$FD93`): coco3-style two map sets. Set 0 = kernel (identity), set 1 = current process (reloaded lazily from a 16-byte page table). Windows at `$A000` / `$B000` give the kernel access to any physical page for user-memory access and `fork` copies.
* **Memory detection** (`memprobe` in `fm11.s`, after MK09): probes in 128KB steps through the MMU window, restores what it touched, and builds the page pool from the result.
* **Page manager** `bank4k.c` (derived from `bank8k.c`): 4KB pages, per-process page table, reference counts for shared pages.
* **Process size**: if the binary does not set `a_size`, text+data+bss rounded up to whole pages plus 2KB (16KB when the pool is 160KB or more) for stack and heap. `chmem` gives a program more room. The last page of a program is also the page holding `udata`, so a process costs one page less.
* **Text sharing**: `fork` does not copy pages that hold only program text. The MMU has no write protection, so this relies on programs not writing their text.
* **Swap**: when `fork` / `exec` / swap-in cannot get enough free pages, the idle process that has waited longest is written to the swap partition (type `0x7F`, found at boot, 120 blocks per process) and read back when it is scheduled. The disk DMA addresses physical pages directly, so no mapping is needed.

### Disk images

Prebuilt images are in `out_mmu/` (raw 2HD, 1,021,696 bytes; `.hfe` for FlashFloppy / Gotek):

| File | Content |
|---|---|
| `fuzix_mmu_fd0.img` / `.hfe` | Boot disk: IPL, kernel, root file system (1400 blocks) **and a 480-block swap partition** (`hda2`) |
| `fuzix_mmu_fd1.img` / `.hfe` | Optional separate swap disk (1920 blocks) for a real second drive. Not needed with the disk above |
| `fuzix.map`, `fuzix_kernel.img` | Link map, kernel in the boot-image format |

Boot log of the combined disk: `hda: hda1 hda2 (swap)`.

### Running

**Emulator** ([Fm11gtk](https://github.com/)-style emulator with `--headless` test mode):

```
fm11 --headless FRAMES out.ppm -f0 fuzix_mmu_fd0.img --dipsw 0xBF --mem 256 --text t.txt --mute \
     --keyat 16000 --keygap 60 --keys $'\r\r\r\r\rroot\r\rls /\r'
```

The first Enter keys answer init's date and time questions. Machines with less memory are slower, so wait longer.

**Real FM-11**: use a 2HD drive or a Gotek with FlashFloppy and `fuzix_mmu_fd0.hfe`. DIPSW as for a 2HD boot disk of MK09; `FF.CFG` as for MK09 (`interface = shugart`, pin02 `nc`, pin34 `rdy`).

* A single Gotek cannot emulate two drives. If you put jumpers on both DS0 and DS1, the second drive shows the same image as the first, so `hdb` is a copy of the boot disk. **Use only the S0 jumper** and the combined disk. Do not write to `/dev/hdb*` in that state.
* For a real second drive, put `fuzix_mmu_fd1.hfe` in a second Gotek set to DS1. The kernel uses the first swap partition it finds, so build the boot disk without the swap partition in that case (`-S` omitted, root 1800 blocks).

### Building

Needs the m6809 `gcc` 4.6.4 (as used by FUZIX), `lwtools`, `perl`, `python3`, `gcc`, `make`, `yacc`, `git`.

```
./fuzix-fm11mmu/build_fm11mmu.sh WORKDIR
```

fetches the FUZIX revision the port was made with, copies `platform-fm11mmu/` into it, builds kernel, libraries and a minimal set of commands, makes the root file system and writes `fuzix_fd0.img` / `fuzix_fd1.img`. Variables: `BSIZE` (root blocks, default 1400), `SWAP0BLKS` (swap on drive 0, default 480), `SWAPBLKS` (swap disk, default 1920). By hand: `make TARGET=fm11mmu YACC=yacc kernel`.

`fuzix-fm11/mkfd.py` builds the disk images (`-b` kernel blocks, `-S` swap on drive 0, `-s`/`-o1` separate swap disk, `-u` a `/usr` file system).

### Layout of the kernel (stage 2)

| Logical | Use |
|---|---|
| `0000–EDFF` | process pages (kernel text/data below `$A000` in map set 0) |
| `EE00–EFFF` | `udata` + kernel stack of the process |
| `F000–FBFF` | common (map switching, syscall/IRQ entry, drivers) — same physical page in every map |
| `FC00–FFFF` | not remapped: shared RAM with the display sub-CPU, I/O, RAM vectors |

Physical pages 0–9 belong to the kernel, 10–13 and 16..top form the process pool, 14 = udata of the first process, 15 = common. More detail: [`DESIGN_MMU.md`](DESIGN_MMU.md) (Japanese/English notes).

### Hardware references

FM-7 / FM-11 Application Note (MMU, DMA, FDC), the FM-11 boot ROM IPL conventions, and the MK09 FM-11 port (`mk09/bsp/fm11`) for the display sub-CPU, keyboard and floppy code.

### License and credits

Copyright (c) 2026 KAYANUMA Shin'ichi (FM-11 port).

* The FM-11 port (`platform-fm11*`, `mkfd.py`, `mkimage.py`, the build scripts) is **GPL-2.0-only**, the same as the FUZIX kernel it is part of (`LICENSE`, SPDX header in each source file; the few files without a header, such as `fuzix.link`, `map.info` and `fuzix.export`, are under the same license).
* `fuzix-fm11/boot/ipl_fm11_2hd.s` (the IPL boot sector, from MK09) is **MIT**, Copyright (c) 2026 YUKARI Semiconductor Devices (`LICENSE-MIT`). It is a stand-alone boot sector and is not linked into the kernel.
* FUZIX itself is by Alan Cox and contributors (GPL-2.0, libraries LGPL; see the FUZIX `LICENCE` and `CREDITS`). `bank4k.c` is derived from FUZIX `bank8k.c`, and stage 1 from `platform-sim09`.
* "FUJITSU" and "FM-11" are trademarks of their owners. This project is not affiliated with Fujitsu.

---

## 日本語

[FUZIX](https://github.com/EtchedPixels/FUZIX)（Alan Cox らによる UNIX 風 OS）を、**FUJITSU FM-11**（MC6809、2HD フロッピー、RAM 128KB〜1MB、MMU 搭載）へ移植したものです。

このリポジトリには 2 つの移植版があります。

| ディレクトリ | ステージ | 内容 |
|---|---|---|
| `fuzix-fm11/` | 1 | MMU を使わない 64KB フラット構成。メモリ上のプロセスは 1 つで、スワップのみ。FUZIX の `platform-sim09` が元です。 |
| `fuzix-fm11mmu/` | 2 | **MMU 使用**。4KB ページ、複数プロセスの同時常駐、**実装メモリの自動検出と全量使用**（128KB〜1MB）、`fork` 時のテキスト共有、ディスクへのスワップ。 |

特に理由がなければステージ 2（`fuzix-fm11mmu`）を使ってください。

### 状態

* Fm11gtk エミュレータで、メモリ 128 / 256 / 384 / 640 / 1024KB のいずれもログインプロンプトまで起動します。`root`（パスワードなし）でシェルに入り、`ls`、`ps`、`cat`、`dd`、`od`、`mount`、`reboot` などが動きます。
* 実機（896KB 搭載の FM-11）で動作したとの報告があります（バナーは `896K RAM (MMU on), 848K for processes`）。実機での確認は進行中で、2 台目ドライブ上のスワップ区画、未実装メモリの読み出し時の挙動、パリティ NMI（`$FD57`）は**実機では未確認**です。
* `shutdown` / `halt` は `Halted.` と表示して停止します。FM-11 はソフトウェアで電源を切れません。
* `login` で `unable to change owner of controlling tty` と出ますが、今のところ実害はありません。

### ステージ 2 の特徴

* **MMU**（`$FD80〜$FD93`）：coco3 方式の 2 マップセット構成です。セット 0 がカーネル（恒等写像）、セット 1 が現在のプロセスで、16 バイトのページ表から必要なときにだけ再設定します。`$A000` / `$B000` の窓から任意の物理ページに触れるので、ユーザメモリのアクセスや `fork` のコピーに使います。
* **メモリ自動検出**（`fm11.s` の `memprobe`、MK09 由来）：MMU の窓越しに 128KB 刻みで試し書きし、触った内容を元に戻して、結果からページプールを作ります。
* **ページ管理** `bank4k.c`（`bank8k.c` を改造）：4KB ページ、プロセスごとのページ表、共有ページの参照カウント。
* **プロセスサイズ**：バイナリが `a_size` を指定しない場合は、text+data+bss をページ単位に切り上げ、さらにスタックとヒープ用に 2KB（プールが 160KB 以上なら 16KB）を足します。`chmem` で増やせます。プログラムの最後のページは `udata` のページと同じなので、プロセス 1 つあたり 1 ページ節約できます。
* **テキスト共有**：`fork` はプログラムのテキストだけを含むページをコピーしません。この MMU には書き込み保護がないので、プログラムが自分のテキストに書き込まないことが前提です。
* **スワップ**：`fork` / `exec` / スワップインで空きページが足りないときは、最も長く待っているプロセスを、スワップ区画（タイプ `0x7F`、起動時に検出、1 プロセス 120 ブロック）へ丸ごと書き出し、スケジュールされたときに読み戻します。ディスクの DMA は物理ページを直接指定するので、マッピングは不要です。

### ディスクイメージ

ビルド済みのイメージは `out_mmu/` にあります（生の 2HD、1,021,696 バイト。FlashFloppy / Gotek 用に `.hfe` も用意）。

| ファイル | 内容 |
|---|---|
| `fuzix_mmu_fd0.img` / `.hfe` | 起動ディスク：IPL、カーネル、ルートファイルシステム（1400 ブロック）、**スワップ区画 480 ブロック**（`hda2`） |
| `fuzix_mmu_fd1.img` / `.hfe` | 別ドライブ用のスワップ専用ディスク（1920 ブロック）。上の起動ディスクを使うなら不要です |
| `fuzix.map`、`fuzix_kernel.img` | リンクマップ、ブートイメージ形式のカーネル |

この起動ディスクのログは `hda: hda1 hda2 (swap)` となります。

### 実行方法

**エミュレータ**（`--headless` のテストモードがある Fm11gtk 系）：

```
fm11 --headless FRAMES out.ppm -f0 fuzix_mmu_fd0.img --dipsw 0xBF --mem 256 --text t.txt --mute \
     --keyat 16000 --keygap 60 --keys $'\r\r\r\r\rroot\r\rls /\r'
```

最初の Enter は init の日付と時刻の質問への応答です。メモリが少ないほど動作が遅いので、待ち時間を長めにしてください。

**実機の FM-11**：2HD ドライブ、または FlashFloppy を入れた Gotek と `fuzix_mmu_fd0.hfe` を使います。DIPSW は MK09 の 2HD 起動ディスクと同じ、Gotek の `FF.CFG` も MK09 と同じです（`interface = shugart`、pin02 `nc`、pin34 `rdy`）。

* Gotek 1 台で 2 台分のドライブは再現できません。DS0 と DS1 の両方にジャンパを入れると、2 台目も 1 台目と同じイメージを返し、`hdb` が起動ディスクのコピーに見えます。**ジャンパは S0 だけ**にして、上の同居版ディスクを使ってください。その状態で `/dev/hdb*` に書き込まないでください。
* 本物の 2 台目ドライブを使うなら、DS1 に設定した 2 台目の Gotek に `fuzix_mmu_fd1.hfe` を入れます。カーネルは最初に見つけたスワップ区画を使うので、その場合は起動ディスクをスワップ区画なし（`-S` を付けず、ルート 1800 ブロック）で作ってください。

### ビルド

m6809 用 `gcc` 4.6.4（FUZIX が使うもの）、`lwtools`、`perl`、`python3`、`gcc`、`make`、`yacc`、`git` が必要です。

```
./fuzix-fm11mmu/build_fm11mmu.sh WORKDIR
```

移植に使った FUZIX のリビジョンを取得し、`platform-fm11mmu/` をコピーして、カーネル・ライブラリ・最小限のコマンドをビルドし、ルートファイルシステムを作って `fuzix_fd0.img` / `fuzix_fd1.img` を出力します。環境変数は `BSIZE`（ルートのブロック数、既定 1400）、`SWAP0BLKS`（ドライブ 0 のスワップ、既定 480）、`SWAPBLKS`（スワップ専用ディスク、既定 1920）です。手作業なら `make TARGET=fm11mmu YACC=yacc kernel` です。

ディスクイメージは `fuzix-fm11/mkfd.py` で作ります（`-b` カーネル用ブロック数、`-S` ドライブ 0 のスワップ、`-s` / `-o1` スワップ専用ディスク、`-u` `/usr` 用ファイルシステム）。

### メモリ配置（ステージ 2）

| 論理アドレス | 用途 |
|---|---|
| `0000〜EDFF` | プロセスのページ（カーネルのテキスト・データはマップセット 0 の `$A000` 未満） |
| `EE00〜EFFF` | プロセスの `udata` とカーネルスタック |
| `F000〜FBFF` | コモン（マップ切替、システムコール/IRQ の入口、ドライバ）。どのマップでも同じ物理ページ |
| `FC00〜FFFF` | マップ対象外：表示サブ CPU との共有 RAM、I/O、RAM ベクタ |

物理ページ 0〜9 がカーネル、10〜13 と 16 以上がプロセス用プール、14 が最初のプロセスの udata、15 がコモンです。詳細は [`DESIGN_MMU.md`](DESIGN_MMU.md) を参照してください。

### ハードウェア資料

FM-7/FM-11 アプリケーションノート（MMU、DMA、FDC）、FM-11 のブート ROM の IPL 規約、表示サブ CPU・キーボード・フロッピーのコードは MK09 の FM-11 版（`mk09/bsp/fm11`）を参考にしています。

### ライセンスと謝辞

Copyright (c) 2026 KAYANUMA Shin'ichi（FM-11 版）。

* FM-11 版（`platform-fm11*`、`mkfd.py`、`mkimage.py`、ビルドスクリプト）は、組み込み先の FUZIX カーネルと同じ **GPL-2.0-only** です（`LICENSE`、各ソースファイルの先頭に SPDX 表記）。`fuzix.link`、`map.info`、`fuzix.export` など表記のないファイルも同じライセンスです。
* `fuzix-fm11/boot/ipl_fm11_2hd.s`（MK09 由来の IPL ブートセクタ）は **MIT** で、Copyright (c) 2026 YUKARI Semiconductor Devices です（`LICENSE-MIT`）。単独のブートセクタで、カーネルにはリンクされません。
* FUZIX 本体は Alan Cox らの作品です（GPL-2.0、ライブラリは LGPL。FUZIX の `LICENCE` と `CREDITS` を参照）。`bank4k.c` は FUZIX の `bank8k.c`、ステージ 1 は `platform-sim09` が元です。
* 「FUJITSU」「FM-11」は各権利者の商標です。本プロジェクトは富士通とは無関係です。
