# FUZIX for the FUJITSU MICRO 11 (FM-11) / FUJITSU MICRO 11 (FM-11) 向け FUZIX

[日本語](#日本語) | [English](#english)

---

## English

A port of [FUZIX](https://github.com/EtchedPixels/FUZIX) (a UNIX-like OS by Alan Cox and contributors) to the **FUJITSU MICRO 11** (FM-11) (Motorola MC6809, 2HD floppies, 128KB–1MB RAM, MMU).

There are two ports in this repository:

| Directory | Level | What it is |
|---|---|---|
| `fuzix-fm11/` | 1 | MMU off, 64KB flat, one process in memory, swap only. Derived from [`platform-sim09`](https://github.com/kaya-z/sim09/tree/master/fuzix/platform-sim09) (the FUZIX platform of sim09). |
| `fuzix-fm11mmu/` | 2 | **MMU on**: 4KB pages, several processes in RAM, **installed memory detected automatically and all of it used** (128KB–1MB), text sharing on `fork`, swap to disk. |

Use Level 2 (`fuzix-fm11mmu`) unless you have a reason not to.

### Status

* **Level 2 boots on a real FM-11 with 896KB** (the banner shows `896K RAM (MMU on), 848K for processes`). `root` (empty password) gets a shell and the commands that only read (`ls`, `ps`, `cat`, `od` ...) work.
* **Known problem on the real machine: writing to a floppy disk emulator based on FlashFloppy (Gotek) does not work yet.** Real floppy drives have not been tried. Creating a file silently fails, so `/var/run/utmp` is not created, `reboot` / `shutdown` (which need `/var/run/initctl`) have no effect, and Level 1, which cannot run without swap writes, stops with `_switchin: FAIL`. The same happens with MK09 on the same hardware, so the FlashFloppy emulation may not accept writes from the FM-11. The cause is not identified yet; under investigation.
* `reboot -f` restarts the machine; `halt` stops it (`Halted.`). The FM-11 cannot be switched off by software.
* Not verified on a real machine: swap, a second drive, the behaviour of unmapped memory reads and the parity NMI (`$FD57`).

### Features of Level 2

* **MMU** (`$FD80–$FD93`): the FM-11's own MMU (16 map sets of 16 × 4KB pages, a window at `$7C00`, `$FC00–$FFFF` not remapped). The kernel uses only two of the map sets, the way the FUZIX CoCo 3 port does: set 0 = kernel (identity), set 1 = current process (reloaded lazily from a 16-byte page table). Windows at `$A000` / `$B000` give the kernel access to any physical page for user-memory access and `fork` copies.
* **Memory detection** (`memprobe` in `fm11.s`, after [MK09's `memprobe`](https://github.com/kaya-z/sim09/blob/master/mk09/arch/m6809/kernel.s)): probes in 128KB steps through the MMU window, restores what it touched, and builds the page pool from the result.
* **Page manager** `bank4k.c` (derived from `bank8k.c`): 4KB pages, per-process page table, reference counts for shared pages.
* **Process size**: if the binary does not set `a_size`, text+data+bss rounded up to whole pages plus 2KB (16KB when the pool is 160KB or more) for stack and heap. `chmem` gives a program more room. The last page of a program is also the page holding `udata`, so a process costs one page less.
* **Text sharing**: `fork` does not copy pages that hold only program text. The MMU has no write protection, so this relies on programs not writing their text.
* **Swap**: when `fork` / `exec` / swap-in cannot get enough free pages, the idle process that has waited longest is written to the swap partition (type `0x7F`, found at boot, 120 blocks per process) and read back when it is scheduled. The disk DMA addresses physical pages directly, so no mapping is needed.

### Disk images

Prebuilt images are in `diskimage/mmu/` (Level 2) and `diskimage/no_mmu/` (Level 1). The `.img` files are raw 2HD disks (1,021,696 bytes); the `.hfe` files are the same disks for FlashFloppy / Gotek (3,233,792 bytes). The contents below were checked from the partition tables of the images.

**Level 2 (`diskimage/mmu/`, recommended)**

| File | Content | Use |
|---|---|---|
| `fuzix_mmu_fd0.img` / `.hfe` | **Boot disk**: IPL, kernel (145 sectors), root file system (`hda1`, 1400 blocks) and swap partition (`hda2`, 480 blocks, type `0x7F`). The `.img` and the `.hfe` are the same disk | Drive 0 |
| `fuzix_mmu_fd0_noswap.img` / `.hfe` | Boot disk for a **real second drive**: IPL, kernel, root file system (`hda1`, 1800 blocks), no swap partition | Drive 0 (with a swap disk in drive 1) |
| `fuzix_mmu_fd1.img` / `.hfe` | Swap-only disk: no IPL, kernel or file system; one swap partition of 1920 blocks (16 processes). For a real second drive | Drive 1. Not needed with the boot disk above, which has its own swap partition |
| `fuzix_kernel.img` | The kernel alone (boot-image format) | Reference |
| `fuzix.map` | Link map | Debugging |
| `FF.CFG` | FlashFloppy configuration (`interface = shugart`, `pin02 = nc`, `pin34 = rdy`, `motor-delay = ignore`, `nav-mode = native`) | Put it in the root of the USB stick |

**Level 1 (`diskimage/no_mmu/`)**

| File | Content | Use |
|---|---|---|
| `fuzix_fd0.img` / `.hfe` | **Boot disk**: IPL, kernel (127 sectors), root file system (`hda1`, 1400 blocks) and swap partition (`hda2`, 480 blocks, type `0x7F`). Level 1 keeps one process in memory and needs a swap partition to run at all | Drive 0 (one drive is enough) |
| `fuzix_fd0_noswap.img` / `.hfe` | Boot disk for a **real second drive**: root file system 1800 blocks, no swap partition | Drive 0, with `fuzix_fd1` in drive 1 |
| `fuzix_fd1.img` / `.hfe` | Swap-only disk (480 blocks, type `0x7F`) | Drive 1, only with `fuzix_fd0_noswap`. Without any swap partition Level 1 stops right after `init version` with `_switchin: FAIL` |
| `fuzix_kernel.img`, `fuzix.map`, `ipl_2hd.bin` | The kernel alone, link map, the IPL (486 bytes) | Reference |

Boot log of the Level 2 boot disk: `hda: hda1 hda2 (swap)`.

### Running

**Real FM-11**: use a 2HD drive or a Gotek with FlashFloppy and `fuzix_mmu_fd0.hfe`. `FF.CFG`: `interface = shugart`, pin02 `nc`, pin34 `rdy`.

* A single Gotek cannot emulate two drives. If you put jumpers on both DS0 and DS1, the second drive shows the same image as the first, so `hdb` is a copy of the boot disk. **Use only the S0 jumper** and the combined disk. Do not write to `/dev/hdb*` in that state.
* For a real second drive, put `fuzix_mmu_fd1.hfe` in a second Gotek set to DS1. The kernel uses the first swap partition it finds, so boot from `fuzix_mmu_fd0_noswap.img` (no swap partition) in that case. A floppy that is not a swap disk yet is formatted physically on another system (FUZIX has no format command: the driver only issues restore, seek and sector read/write), then log in and run `dd if=/etc/swapmbr of=/dev/hdb bs=512 count=1` (writes the partition table: one swap partition of 1920 blocks, type `0x7F`) and reboot; the boot log then shows `hdb: hdb1 (swap)`. Never write it to `/dev/hda`: it would destroy the partition table of the boot disk.

### Building

Needs the m6809 `gcc` 4.6.4 (as used by FUZIX), `lwtools`, `perl`, `python3`, `gcc`, `make`, `yacc`, `git`.

```
./fuzix-fm11mmu/build_fm11mmu.sh WORKDIR
```

fetches the FUZIX revision the port was made with, copies `platform-fm11mmu/` into it, builds kernel, libraries and a minimal set of commands, makes the root file systems and writes `fuzix_fd0.img` (with swap), `fuzix_fd0_noswap.img` and `fuzix_fd1.img`. Variables: `BSIZE` (root blocks, default 1400), `SWAP0BLKS` (swap on drive 0, default 480), `SWAPBLKS` (swap disk, default 1920), `BSIZE2` (root blocks of the no-swap disk, default 1800). By hand: `make TARGET=fm11mmu YACC=yacc kernel`.

`fuzix-fm11/mkfd.py` builds the disk images (`-b` kernel blocks, `-S` swap on drive 0, `-s`/`-o1` separate swap disk, `-u` a `/usr` file system).

### FM-11 specific commands

None. The user space is the standard FUZIX one (the V7 shell and the FUZIX utilities); everything specific to the FM-11 is in the kernel and in the tools that build the disks:

* kernel drivers: console on the display sub-CPU, keyboard, 2HD floppy (MB8877 + DMA), the MMU and the memory detection;
* `fuzix-fm11/mkfd.py` builds the boot disk (IPL, partition table, kernel, root file system, optional swap partition);
* the root file system is the minimal FUZIX one, with `od` and `/etc/swapmbr` (the partition table of a swap disk, see above) added. Use `chmem` to give a program more memory than the default size.

### Layout of the kernel (Level 2)

| Logical | Use |
|---|---|
| `0000–EDFF` | process pages (kernel text/data below `$A000` in map set 0) |
| `EE00–EFFF` | `udata` + kernel stack of the process |
| `F000–FBFF` | common (map switching, syscall/IRQ entry, drivers) — same physical page in every map |
| `FC00–FFFF` | not remapped: shared RAM with the display sub-CPU, I/O, RAM vectors |

Physical pages 0–9 belong to the kernel, 10–13 and 16..top form the process pool, 14 = udata of the first process, 15 = common. More detail: [`docs/DESIGN_MMU.md`](docs/DESIGN_MMU.md) (Japanese/English notes).

### Hardware references

FM-7 / FM-11 Application Note (MMU, DMA, FDC), the FM-11 boot ROM IPL conventions, and the [MK09 FM-11 port (`mk09/bsp/fm11`)](https://github.com/kaya-z/sim09/tree/master/mk09/bsp/fm11) for the display sub-CPU, keyboard and floppy code.

### License and credits

Copyright (c) 2026 KAYANUMA Shin'ichi (FM-11 port).

* The FM-11 port (`platform-fm11*`, `mkfd.py`, `mkimage.py`, the build scripts) is **GPL-2.0-only**, the same as the FUZIX kernel it is part of (`LICENSE`, SPDX header in each source file; the few files without a header, such as `fuzix.link`, `map.info` and `fuzix.export`, are under the same license).
* `fuzix-fm11/boot/ipl_fm11_2hd.s` (the IPL boot sector, from [MK09](https://github.com/kaya-z/sim09/blob/master/mk09/boot/ipl_fm11_2hd.s)) is **MIT**, Copyright (c) 2026 YUKARI Semiconductor Devices (`LICENSE-MIT`). It is a stand-alone boot sector and is not linked into the kernel.
* FUZIX itself is by Alan Cox and contributors (GPL-2.0, libraries LGPL; see the FUZIX `LICENCE` and `CREDITS`). `bank4k.c` is derived from FUZIX `bank8k.c`, and Level 1 from [`platform-sim09`](https://github.com/kaya-z/sim09/tree/master/fuzix/platform-sim09).
* This port was developed with the help of [Claude Code](https://claude.com/claude-code) (Anthropic's AI coding tool); the author directed the work.
* "FUJITSU", "FUJITSU MICRO" and "FM-11" are trademarks of their owners. This project is not affiliated with Fujitsu.

---

## 日本語

[FUZIX](https://github.com/EtchedPixels/FUZIX)（Alan Cox らによる UNIX 風 OS）を、**FUJITSU MICRO 11**（FM-11、MC6809、2HD フロッピー、RAM 128KB〜1MB、MMU 搭載）へ移植したものです。

このリポジトリには 2 つの移植版があります。

| ディレクトリ | レベル | 内容 |
|---|---|---|
| `fuzix-fm11/` | 1 | MMU を使わない 64KB フラット構成。メモリ上のプロセスは 1 つで、スワップのみ。[`platform-sim09`](https://github.com/kaya-z/sim09/tree/master/fuzix/platform-sim09)（sim09 用の FUZIX プラットフォーム）が元です。 |
| `fuzix-fm11mmu/` | 2 | **MMU 使用**。4KB ページ、複数プロセスの同時常駐、**実装メモリの自動検出と全量使用**（128KB〜1MB）、`fork` 時のテキスト共有、ディスクへのスワップ。 |

特に理由がなければレベル 2（`fuzix-fm11mmu`）を使ってください。

### 状態

* **レベル 2 は、実機（896KB 搭載の FM-11）で起動します**（バナーは `896K RAM (MMU on), 848K for processes`）。`root`（パスワードなし）でシェルに入り、読み出しだけのコマンド（`ls`、`ps`、`cat`、`od` など）が使えます。
* **実機での既知の問題：FlashFloppy を使ったフロッピーディスクエミュレータ（Gotek）への書き込みが、まだ動きません。** 本物のフロッピードライブでは試していません。ファイルを作ってもエラーなしで失敗するため、`/var/run/utmp` が作られず、`/var/run/initctl` を必要とする `reboot` / `shutdown` も効きません。スワップの書き込みができないレベル 1 は `_switchin: FAIL` で止まります。同じハードウェアでは MK09 でも同じ現象が出るので、FlashFloppy のエミュレーションが FM-11 からの書き込みを受け付けない可能性があります。原因はまだ特定できておらず、調査中です。
* `reboot -f` は再起動し、`halt` は `Halted.` と表示して停止します。FM-11 はソフトウェアで電源を切れません。
* 実機で未確認のもの：スワップ、2 台目ドライブ、未実装メモリの読み出し時の挙動、パリティ NMI（`$FD57`）。

### レベル 2 の特徴

* **MMU**（`$FD80〜$FD93`）：FM-11 独自の MMU です（4KB × 16 ページのマップセットが 16 組、`$7C00` に窓、`$FC00〜$FFFF` は対象外）。カーネルは、FUZIX の CoCo 3 版と同じように、そのうち 2 組だけを使います。セット 0 がカーネル（恒等写像）、セット 1 が現在のプロセスで、16 バイトのページ表から必要なときにだけ再設定します。`$A000` / `$B000` の窓から任意の物理ページに触れるので、ユーザメモリのアクセスや `fork` のコピーに使います。
* **メモリ自動検出**（`fm11.s` の `memprobe`、[MK09 の `memprobe`](https://github.com/kaya-z/sim09/blob/master/mk09/arch/m6809/kernel.s) 由来）：MMU の窓越しに 128KB 刻みで試し書きし、触った内容を元に戻して、結果からページプールを作ります。
* **ページ管理** `bank4k.c`（`bank8k.c` を改造）：4KB ページ、プロセスごとのページ表、共有ページの参照カウント。
* **プロセスサイズ**：バイナリが `a_size` を指定しない場合は、text+data+bss をページ単位に切り上げ、さらにスタックとヒープ用に 2KB（プールが 160KB 以上なら 16KB）を足します。`chmem` で増やせます。プログラムの最後のページは `udata` のページと同じなので、プロセス 1 つあたり 1 ページ節約できます。
* **テキスト共有**：`fork` はプログラムのテキストだけを含むページをコピーしません。この MMU には書き込み保護がないので、プログラムが自分のテキストに書き込まないことが前提です。
* **スワップ**：`fork` / `exec` / スワップインで空きページが足りないときは、最も長く待っているプロセスを、スワップ区画（タイプ `0x7F`、起動時に検出、1 プロセス 120 ブロック）へ丸ごと書き出し、スケジュールされたときに読み戻します。ディスクの DMA は物理ページを直接指定するので、マッピングは不要です。

### ディスクイメージ

ビルド済みのイメージは `diskimage/mmu/`（レベル 2）と `diskimage/no_mmu/`（レベル 1）にあります。`.img` は生の 2HD（1,021,696 バイト）、`.hfe` は同じディスクを FlashFloppy / Gotek 用に変換したもの（3,233,792 バイト）です。以下の内容は、イメージのパーティションテーブルを読んで確認したものです。

**レベル 2（`diskimage/mmu/`、推奨）**

| ファイル | 内容 | 使い方 |
|---|---|---|
| `fuzix_mmu_fd0.img` / `.hfe` | **起動ディスク**：IPL、カーネル（145 セクタ）、ルートファイルシステム（`hda1`、1400 ブロック）、スワップ区画（`hda2`、480 ブロック、タイプ `0x7F`）。`.img` と `.hfe` は同じディスクです | ドライブ 0 |
| `fuzix_mmu_fd0_noswap.img` / `.hfe` | **本物の 2 台目ドライブ用**の起動ディスク：IPL、カーネル、ルートファイルシステム（`hda1`、1800 ブロック）。スワップ区画は無し | ドライブ 0（ドライブ 1 にスワップディスク） |
| `fuzix_mmu_fd1.img` / `.hfe` | スワップ専用ディスク：IPL・カーネル・ファイルシステムは無く、1920 ブロック（16 プロセス分）のスワップ区画が 1 つだけです。本物の 2 台目ドライブ用 | ドライブ 1。上の起動ディスクには自前のスワップ区画があるので、それを使うなら不要です |
| `fuzix_kernel.img` | カーネル単体（ブートイメージ形式） | 参照用 |
| `fuzix.map` | リンクマップ | デバッグ用 |
| `FF.CFG` | FlashFloppy の設定（`interface = shugart`、`pin02 = nc`、`pin34 = rdy`、`motor-delay = ignore`、`nav-mode = native`） | USB メモリの直下に置く |

**レベル 1（`diskimage/no_mmu/`）**

| ファイル | 内容 | 使い方 |
|---|---|---|
| `fuzix_fd0.img` / `.hfe` | **起動ディスク**：IPL、カーネル（127 セクタ）、ルートファイルシステム（`hda1`、1400 ブロック）、スワップ区画（`hda2`、480 ブロック、タイプ `0x7F`）。レベル 1 はメモリ上のプロセスが 1 つなので、スワップ区画が無いと動きません | ドライブ 0（1 台で動きます） |
| `fuzix_fd0_noswap.img` / `.hfe` | **本物の 2 台目ドライブ用**の起動ディスク：ルートファイルシステム 1800 ブロック、スワップ区画なし | ドライブ 0（ドライブ 1 に `fuzix_fd1`） |
| `fuzix_fd1.img` / `.hfe` | スワップ専用ディスク（480 ブロック、タイプ `0x7F`） | ドライブ 1。`fuzix_fd0_noswap` と組み合わせる場合だけ使います。スワップ区画がどこにも無いと、レベル 1 は `init version` の直後に `_switchin: FAIL` で止まります |
| `fuzix_kernel.img`、`fuzix.map`、`ipl_2hd.bin` | カーネル単体、リンクマップ、IPL（486 バイト） | 参照用 |

レベル 2 の起動ディスクのログは `hda: hda1 hda2 (swap)` となります。

### 実行方法

**実機の FM-11**：2HD ドライブ、または FlashFloppy を入れた Gotek と `fuzix_mmu_fd0.hfe` を使います。Gotek の `FF.CFG` は `interface = shugart`、pin02 `nc`、pin34 `rdy` にします。

* Gotek 1 台で 2 台分のドライブは再現できません。DS0 と DS1 の両方にジャンパを入れると、2 台目も 1 台目と同じイメージを返し、`hdb` が起動ディスクのコピーに見えます。**ジャンパは S0 だけ**にして、上の同居版ディスクを使ってください。その状態で `/dev/hdb*` に書き込まないでください。
* 本物の 2 台目ドライブを使うなら、DS1 に設定した 2 台目の Gotek に `fuzix_mmu_fd1.hfe` を入れます。カーネルは最初に見つけたスワップ区画を使うので、その場合は、スワップ区画の無い `fuzix_mmu_fd0_noswap.img` から起動してください。まだスワップ用になっていないフロッピーは、別の環境で物理フォーマットします（FUZIX にフォーマット命令は無く、ドライバが出すのは restore・seek・セクタの読み書きだけです）。そのうえでログインし、`dd if=/etc/swapmbr of=/dev/hdb bs=512 count=1`（区画テーブルを書き込みます。1920 ブロックのスワップ区画 1 つ、タイプ `0x7F`）を実行して再起動します。起動ログに `hdb: hdb1 (swap)` と出れば成功です。書き込み先を `/dev/hda` にすると起動ディスクの区画テーブルが消えるので、注意してください。

### ビルド

m6809 用 `gcc` 4.6.4（FUZIX が使うもの）、`lwtools`、`perl`、`python3`、`gcc`、`make`、`yacc`、`git` が必要です。

```
./fuzix-fm11mmu/build_fm11mmu.sh WORKDIR
```

移植に使った FUZIX のリビジョンを取得し、`platform-fm11mmu/` をコピーして、カーネル・ライブラリ・最小限のコマンドをビルドし、ルートファイルシステムを作って `fuzix_fd0.img`（スワップ同居）、`fuzix_fd0_noswap.img`、`fuzix_fd1.img` を出力します。環境変数は `BSIZE`（ルートのブロック数、既定 1400）、`SWAP0BLKS`（ドライブ 0 のスワップ、既定 480）、`SWAPBLKS`（スワップ専用ディスク、既定 1920）、`BSIZE2`（スワップ無しディスクのルートのブロック数、既定 1800）です。手作業なら `make TARGET=fm11mmu YACC=yacc kernel` です。

ディスクイメージは `fuzix-fm11/mkfd.py` で作ります（`-b` カーネル用ブロック数、`-S` ドライブ 0 のスワップ、`-s` / `-o1` スワップ専用ディスク、`-u` `/usr` 用ファイルシステム）。

### FM-11 向けの独自コマンド

ありません。ユーザ空間は標準の FUZIX（V7 シェルと FUZIX のユーティリティ）のままで、FM-11 固有の部分はカーネルとディスクを作るツールにあります。

* カーネルのドライバ：表示サブ CPU のコンソール、キーボード、2HD フロッピー（MB8877 と DMA）、MMU とメモリ自動検出。
* `fuzix-fm11/mkfd.py`：起動ディスク（IPL、区画テーブル、カーネル、ルートファイルシステム、任意でスワップ区画）を作ります。
* ルートファイルシステムは FUZIX の最小構成に `od` と `/etc/swapmbr`（スワップディスクの区画テーブル。上記参照）を足したものです。プログラムに既定より多くのメモリを与えるときは `chmem` を使います。

### メモリ配置（レベル 2）

| 論理アドレス | 用途 |
|---|---|
| `0000〜EDFF` | プロセスのページ（カーネルのテキスト・データはマップセット 0 の `$A000` 未満） |
| `EE00〜EFFF` | プロセスの `udata` とカーネルスタック |
| `F000〜FBFF` | コモン（マップ切替、システムコール/IRQ の入口、ドライバ）。どのマップでも同じ物理ページ |
| `FC00〜FFFF` | マップ対象外：表示サブ CPU との共有 RAM、I/O、RAM ベクタ |

物理ページ 0〜9 がカーネル、10〜13 と 16 以上がプロセス用プール、14 が最初のプロセスの udata、15 がコモンです。詳細は [`docs/DESIGN_MMU.md`](docs/DESIGN_MMU.md) を参照してください。

### ハードウェア資料

FM-7/FM-11 アプリケーションノート（MMU、DMA、FDC）、FM-11 のブート ROM の IPL 規約、表示サブ CPU・キーボード・フロッピーのコードは [MK09 の FM-11 版（`mk09/bsp/fm11`）](https://github.com/kaya-z/sim09/tree/master/mk09/bsp/fm11)を参考にしています。

### ライセンスと謝辞

Copyright (c) 2026 KAYANUMA Shin'ichi（FM-11 版）。

* FM-11 版（`platform-fm11*`、`mkfd.py`、`mkimage.py`、ビルドスクリプト）は、組み込み先の FUZIX カーネルと同じ **GPL-2.0-only** です（`LICENSE`、各ソースファイルの先頭に SPDX 表記）。`fuzix.link`、`map.info`、`fuzix.export` など表記のないファイルも同じライセンスです。
* `fuzix-fm11/boot/ipl_fm11_2hd.s`（[MK09](https://github.com/kaya-z/sim09/blob/master/mk09/boot/ipl_fm11_2hd.s) 由来の IPL ブートセクタ）は **MIT** で、Copyright (c) 2026 YUKARI Semiconductor Devices です（`LICENSE-MIT`）。単独のブートセクタで、カーネルにはリンクされません。
* FUZIX 本体は Alan Cox らの作品です（GPL-2.0、ライブラリは LGPL。FUZIX の `LICENCE` と `CREDITS` を参照）。`bank4k.c` は FUZIX の `bank8k.c`、レベル 1 は [`platform-sim09`](https://github.com/kaya-z/sim09/tree/master/fuzix/platform-sim09) が元です。
* この移植は [Claude Code](https://claude.com/claude-code)（Anthropic の AI コーディングツール）の支援を受けて開発しました。作者が方針を決め、実機で動作を確認しています。
* 「FUJITSU」「FUJITSU MICRO」「FM-11」は各権利者の商標です。本プロジェクトは富士通とは無関係です。
