# checkd: ファイルの変化をコンパイラへ明示的に渡す形への作り替え（設計）

2026-10-21。コードは書いていない。重い処理は流していない（javap とファイルの読みと、ハッシュの時間を 1 回測っただけ）。
**[確]** は手で確かめた事、**[推]** は見込み。

**決めた事（見回り役 2026-10-21。§7 の 4 つへの答え。各節に反映済み）**:
1. 常駐は **flixlint の `Resident` に check の口を足して、lint・refactor と共有する**（エンジンには置かない）。共有の口と順は §4.4、2 枚を合わせた段の順は §6.1 が正（refactor-tool-design §8 はここを指す）。
2. **test はゲームのコードを動かすので別の JVM**（共有の常駐には入れない）。形は §4.3・段 T。
3. **3 秒の待ちのブランチ（ababup1192/checkd-wait）は入れない**。作業はエンジンの main（0.54 系）から枝を切る（checkd-wait の未コミットの差分の上に積まない）。
4. **検査の途中で書き換わったら答えを捨ててやり直す（3 回まで。その後は素の CLI）**（§3.1）。

読んだ物: エンジン checkd（作業場 `flix_game_engine-checkd-wait` = 0.54.0 ＋未コミットの差分。エンジンの main の checkout は 0.49 で古い）の
`go/internal/checkd/`（sources.go・daemon.go・client.go）・`docs/checkd.md`・`bin/flix`・`bin/headless-run`・`go/internal/resident/manifest.go`、
flixlint の origin/main（v0.6.5、`shim/Resident.scala`・`shim/Facts.scala`・`bin/flixlint`。手元の checkout は 32 コミット遅れ）、
`~/.flix_ge_studio/engines/0.54.0/bin/flix.jar`（Flix 0.78）の `Flix`・`Bootstrap`・`ProjectFiles`・`runtime.shell.Shell` を javap。

---

## 0. 結論

1. **repl をやめ、Flix の `Flix.addSource(path, 中身, SecurityContext)` に「このファイルをこの中身で」と渡す常駐に替える**。
   checkd の側でファイルの変化を待つ・監視する仕組みは持たない。check を頼まれた時に、全部の .flix を読んで SHA-256 を取り、
   前回渡した中身と違うファイルだけを渡す（172 ファイル・3.8 MB で読みとハッシュは 0.13 s 以下 [確: shasum で測った上限]）。
2. **答えに「どの中身を検査したか」（ソースの版 = 各ファイルのハッシュから作る 1 つのハッシュ）を付け、クライアントが答えを受けた後に
   自分でディスクから版を取り直して比べる。違えば答えを使わず、やり直すか素の CLI に落ちる**。古い緑（今のディスクより前の中身に対して出た「通った」の答え。赤なら古い赤）は「答えを受け取る条件」で構造的に出なくなる。
3. 常駐の置き場は **flixlint の `Resident` に `check` の口を足す形**（決めた事 1）。flixlint は既に同じ API（`new Flix`・`addFile`・`remFile`・`check`）で
   常駐を持ち、依存の読み・identity（身元）・Unix ソケットの口・`flix.jar` の版ごとの jar がある。1 つの JVM・1 つのプロジェクトの `Flix` を
   check・lint・refactor の索引で共有し、メモリの重い部分（型付きの AST）を 2 つ持たない。共有の口は §4.4、段の順は §6.1。
4. `test` は共有の常駐に入れず別の JVM で走らせる（決めた事 2。利用者のコードを動かすので、固まり・落ちが lint と check まで巻き込む）。
5. 3 秒の待ち（ブランチ `ababup1192/checkd-wait`）は入れない（決めた事 3）。待ち時間に正しさを預ける形そのものを段 3 で消す。

---

## 1. いまの形と、問題の根

### 1.1 いまの流れ [確]

```
make check → bin/fge checkd（Go のクライアント）→ TCP → checkd 常駐（Go）→ パイプ → flix repl（JVM）
```

- repl（`runtime.shell.Shell`）は起動時に `Bootstrap.mkFlix` でソースを全部 `addFile` し、以後は `Bootstrap.startWatching` の
  `FileWatcher`（JDK の WatchService）の知らせを `:check` の前の `refresh()` → `Bootstrap.applyFileChanges(flix)` で取り込む。
  `:reload` に当たる命令は無い（Shell の命令は check・test・run・eval・help・quit ほか）[確: javap]。
- checkd は自分で (mtime, 大きさ) を控え、変わったファイルが repl のポーリングに拾われるまで `:check` を送らない（`sources.go` の `watchWait`・`catchUp`）。
  macOS の待ちは 11 秒（ブランチでは 3 秒）、ほかの OS は 1 秒。
- 守り: 「編集後も同じエラー」なら repl を作り直して確かめる（古い赤の検出）、温めの間に変わったら repl を捨てる、
  src を symlink で束ねたパッケージ（engine_full）は常駐を使わない（書き換えを読み直さず緑を返し続けた実測がある）、Windows は `CHECKD := 0`。

### 1.2 問題の根

- **checkd は repl がどの中身を検査したかを知る手段を持たない**。分かるのは「待った時間」だけで、正しさが JDK のポーリングの間隔
  （仕様に無い値）・機械の混み具合・ファイルシステムの mtime の細かさ（秒単位の所では同じ秒の 2 回目の書き換えを見落とす）・
  `cp -p` のような mtime を戻す書き換え、に依る。
- 古い赤は「編集後も同じエラー」で拾えるが、**古い緑は拾う材料が無い**（緑の答えには比べる物が無い）。
- symlink のソースは、repl の監視がリンクの先の書き換えを知らないので、待っても取り込まれない。

### 1.3 Flix 0.78 の口 [確: javap]

| 口 | 中身 |
|---|---|
| `Flix.addSource(Path, String, SecurityContext)`・`addSource(URI, …)` | 与えた文字列をそのパスのソースとして置く（同じパスなら差し替え） |
| `Flix.addFile(Path, SecurityContext)` | `Files.readAllBytes` で読み、`path.normalize` をキーに `addSource` を呼ぶだけ |
| `Flix.remSource(Path)`・`remFile(Path)` | 外す（`remFile` は `.flix` か確かめて `remSource(path.normalize)`） |
| `Flix.check()` | `(Option[TypedAst.Root], List[CompilationMessage])`。ディスクは読まない |
| `Bootstrap.bootstrap(path, token, formatter, out)` | flix.toml を読み依存を入れる（CLI と同じ） |
| `Bootstrap.mkFlix(options, formatter)` | `new Flix(pkgs, jars, mounts)`・`setOptions`・`setFormatter`・`ProjectFiles.sources` を全部 `addFile` |
| `Bootstrap.check(flix)` | `flix.check()` ＋ `CompilationMessage.formatAll(errors, formatter, root)`。CLI の `flix check` の出力と同じ道 |
| `Bootstrap.test(flix)` | コンパイルしてテストを走らせる（`tools.Tester`） |
| `Bootstrap.startWatching / applyFileChanges` | repl の監視。**呼ばなければ監視は動かない** |

`addSource` は LSP がエディタの未保存の中身を渡すのに使う口でもあり、Flix の中で日常的に通る道 [推]。

---

## 2. 案の比べ（設計書に入れる物 1）

| | A. repl のまま・Go で変化を見つけて待つ | B1. checkd 専用の小さな Api 常駐 | B2. flixlint の Resident に check を足す（推す） |
|---|---|---|---|
| 変化の伝え方 | 伝えられない（repl は自分の監視でしか取り込まない）。Go の fsnotify/FSEvents は「いつ待ち終えるか」を早めに知るだけ | `addSource(path, 中身)` で明示的に渡す | B1 と同じ |
| 古い緑 | 待ち時間の見込みが外れれば出る | 版の比べで出ない（§3） | 同じ |
| symlink のソース（engine_full） | 使えない | 読むのはリンクの先の中身なので使える [推] | 同じ |
| Windows | 監視の作りが OS ごとに違う。今は止めている | OS の監視に依らない | 同じ。Unix ソケットは JDK 16 以上と Windows 10 1803 以上で使える [推] |
| 秒（1 行変えた後） | 待ちの分（macOS 3〜11 s・他 1 s）が残る | 待ちが 0 | 同じ。lint と共有すれば lint 側も速い |
| 版上げの手間 | 無い（CLI の repl をそのまま使う） | `Flix`・`Bootstrap` の口に縛られる | 同じ口に縛られるが、flixlint で既に保守している（0.76 → 0.78 の移行済み [確: 設計書 refactor-tool-design §1.3]） |
| メモリ | repl 1 本（1.2〜3.7 GB） | 常駐 1 本 | lint の常駐と合わせて 1 本にできる（§4） |

- **A を取らない理由**: Go の側でどれだけ早く変化を知っても、repl に中身を渡す口が無い。repl が読んだ中身を後から確かめる口も無い。
  「目印のファイルを src に書いて repl に拾わせ、拾えたら他も拾えたとみなす」形も考えたが、JDK の `PollingWatchService` は
  登録したディレクトリごとに別々の周期で見回る [推: JDK の作り] ので、目印の拾いは他のディレクトリの拾いの証にならない。
  ゲームの src に書き込むのも避けたい。
- **ファイルの監視（fsnotify / FSEvents / ReadDirectoryChangesW）は正しさの土台にしない**。頼まれた時に全部をハッシュする費用が
  0.13 s 以下 [確: プロセス起動込みの上限。常駐の中なら 10〜20 ms と見込む [推]] なので、監視で読む量を減らす得が無い。
  監視は知らせの取りこぼし（FSEvents のまとめ・Windows のバッファのあふれ・Linux の inotify の上限）を自分で扱う必要があり、OS ごとの差を持ち込む。
  後で「保存したらすぐ裏で check を始める」を入れる時だけ、きっかけとして使う（答えの正しさは §3 の版の比べが持つので、取りこぼしても遅くなるだけ）。
- 以前「内部 API の窓口」案を見送った理由は「得が待ちの 11 秒だけで小さい・版上げで壊れうる」だった（ブランチの docs/checkd.md）。
  今は (1) 1 行の変更後の check が約 14〜21 秒になり、待ちの割合が大きい [確: 依頼主の試し]、(2) 正しさ（古い緑・symlink・Windows）の得がある、
  (3) 同じ口に縛られた常駐を flixlint が既に持ち保守している、の 3 点で前提が変わった。

### 2.1 常駐の中の処理（check 1 回）

```
1. 頼み（project の根）を受ける
2. 依存の版（flix.toml・packages.lock・lib の使う fpkg/jar の中身のハッシュ。resident/manifest.go の BuildManifest と同じ考え）を取る。
   変わっていれば `Bootstrap.bootstrap` からやり直して Flix を作り直す（いまの takeSnapshot の置き換え。依存の解決を `Bootstrap` に任せる形は
   refactor-tool-design §8.1 の A と同じ物で、§6.1 の共-2 で 1 回だけ作る）。lib/ の jar のハッシュを毎回取る秒は未測定 [推: natives の jar が大きい]。
3. ソースの一覧を取る（`Bootstrap` が返す `ProjectFiles` の sources をそのまま使う。自前で src/・test/ を歩かない。symlink を辿るかは段 1 の fixture で確かめる）
4. 各ファイルを 1 回だけ読み、bytes と SHA-256 を持つ
5. 前回渡した (path → sha) と比べ、無くなった物は remSource、違う物・新しい物は addSource(path, 4 で読んだ bytes を UTF-8 で)
   （path は addFile と同じ normalize の形。エラーの見出しのパスが CLI と同じになるかは段 0 で確かめる）
6. version = SHA-256( flix.jar の版 ‖ 依存の版 ‖ 並べた (相対パス, sha) の列 )
7. Bootstrap.check(flix) と同じ処理（flix.check と formatAll）
8. 答え = (終了コード, 出力, version)
```

- **4 で読んだ bytes をそのまま 5 で渡す**のが要。flixlint の今の Resident は「bytes を比べてから `addFile`」なので、比べた中身と
  コンパイラが読む中身の間に書き換えが挟まると食い違う。flixlint 側もこの機会に `addSource` へ直す。
- 依存の入れ直し（ネットの取得）は `Bootstrap.bootstrap` が CLI と同じ道でやる。常駐の起動時に 1 回と、依存の版が変わった時だけ。
- オプションは CLI の `flix check` と同じ物を使う（`Bootstrap.mkFlix` に渡す `Options` を CLI の Main と合わせる）。
  flixlint は `Options.Default.copy(lib = All, progress = false)` で「CLI と同じ」としている [確: Facts.compiler のコメント]。lint・refactor も同じ `Flix` を使うので、
  オプションを CLI に揃えると lint の事実が変わりうる。段 1 で、揃えた前後の lint の違反一覧と索引の行が一致するかも見る。

---

## 3. 答えがどの版に対する物かを保証する（設計書に入れる物 2）

### 3.1 受け取りの決まり

```
クライアント:  頼む → 答え (code, 出力, version_checked) を受ける → ディスクから version_now を取り直す
              version_checked == version_now なら答えを使う
              違えば 「検査の間にソースが変わった」としてやり直す（3 回まで）。それでも合わなければ素の CLI へ
```

- 版を作る式は Go（クライアント）と JVM（常駐）の 2 か所に置くことになる。同じ小さな fixture（数ファイル）から同じ 64 字が出ることを
  両方のテストで確かめる（式は「相対パスを / 区切りで・NUL で区切り・並べる」だけの単純な物にする）。
- これで、常駐の中の読み方に誤りがあっても（読み落とし・古い中身を渡した）、**受け取られる答えは「答えを受けた時点のディスクの中身」に対する物だけ**になる。
  version は常駐が実際に渡した bytes から作るので、常駐が古い中身を検査した時は version が今のディスクと合わず、捨てられる。
- 版が合わないのは「検査の途中で書き換えた」時だけで、その時に古い答えを返さないのは CLI より厳しい（CLI は読んだ時点の答えを返す）。
  保存を続けるエージェントが居ると retry が増えるので、retry の回数を常駐の記録に出し、段 2 で数える。
- mtime は一切使わない。秒単位の mtime・`cp -p`・`touch -r` で mtime を戻した書き換え・時計のずれ、のどれも版に影響しない。

### 3.2 常駐の中の不変条件

- 「常駐が `Flix` に渡したソースの集合」＝「`given: Map[path, sha]`」を常に保つ。check の直前に `given` から version を作り直し、6 で作った物と同じかを確かめる（違えば常駐の誤りなので Flix を作り直し、その回は素の CLI へ）。
- Flix の増分の検査そのものの誤り（変えたのに前の結果が残る）は、版の比べでは拾えない。いまの「編集後も同じエラーなら作り直して確かめる」は
  段 2 では残し、作り直した結果が前と違った回数を daemon.log に数える。段 3 の 1 週間で 0 回なら消す（増分の誤りを見つけたら Flix へ報告し、この確かめは
  コンパイラの誤りへの手当てとして、報告の番号を WhyNot に書いて残す）。
  緑の側の増分の誤りは、段 0・段 2 の突き合わせ（同じ中身で常駐と素の CLI の答えを比べる）で数を取り、0 でなければ Flix へ報告する。

### 3.3 プロトコル

- 常駐の答えに `version=<64字>` を足す（flixlint の Resident の枠: 'O'/'E'/'X' に、'V' の枠を足す。枠の全体は §4.4）。
- クライアントの `CHECKD_DEBUG=1` で version と retry の数を出す。daemon.log には毎回 `check #n exit=… version=… retry=… 秒` を残す（段 2 の数え上げに使う）。

---

## 4. flixlint の常駐と 1 つの JVM・1 つのコンパイラに寄せる（設計書に入れる物 3）

### 4.1 寄せて得る物

- メモリ: checkd の repl 1.2〜3.7 GB と flixlint の typed 4.8〜5.2 GB（Mac mini [確: refactor-tool-design §2]）を、型付きの AST 1 つ分にする。
  2 本の和より小さくなる量は測っていない [推: 片方の分がそのまま浮くとは限らない]。共有の常駐の中には、プロジェクトの `Flix` のほかに
  規則のエンジンを組む `Flix`（`State.engineFlix`）と、組んだエンジンの class loader も居る [確: Resident.scala]。予算はこの全部で見る（§4.4 の 6）。
- 秒: check の後の typed の走行（refactor の索引・typed の lint）は、ソースが同じなら `flix.check()` の増分がほぼ何もしないので、歩く時間だけになる [推]。
  ゲームの lint は `--stage resolved` [確: Makefile の FLIXLINT]。`Resolved.run` は毎回 `ChangeSet.Everything` で Lexer から Resolver までを空の状態から流す
  [確: Facts.scala] ので、増分の得は無く、温まった JVM の得（今 8.7 s → 2.8 s [確: refactor-tool-design §8.0、ソースを変えない時]）だけになる。
- refactor の索引（`--spans`）も同じ `Flix` から取れる。

### 4.2 寄せるための条件

1. **ソースの集合を同じにする**。checkd は src と test を全部検査する。ゲームの lint も既に `src test` を渡している [確: Makefile の lint-flixlint-run・lint-list-run]、
   refactor も `src`・`test` [確: fge-refactor の config.go の既定]。どのプロジェクトでもずれないよう、コンパイルする集合は呼び手の引数でなく `Bootstrap` の
   sources（`flix check` と同じ）にし、呼び手の SRC は出力（事実・索引）を絞るだけにする（§4.4 の 4）。
2. **オプションを同じにする**（§2.1）。違うオプションは同じ `Flix` に同居できない。
3. **resolved の段**: `Resolved.run(flix)` は `Flix` から sources を読むだけで、phase を空の状態から呼び、`Flix` の増分の状態（前の check の AST）には
   書かない [確: Facts.scala の Resolved.run を読んだ。thread pool の開け閉めと phaseTimers だけは触る]。なので同じ `Flix` で流す（別の `Flix` を持たない）。
   resolved を挟んだ後の check の出力が素の CLI とバイトまで同じかは、段 0 の (b) を「resolved → check」の順でも流して確かめる。
4. **順番・5. identity・6. ソケット・7. 寿命と予算**: §4.4 にまとめた（refactor-tool-design §8.2 と 1 つの決めにした）。

### 4.3 危うい所

- **障害が 3 つに及ぶ**: 常駐が落ちる・固まると check・lint・refactor が止まる。戻り方は §4.4 の 7。
- **配る物が増える**: エンジンの checkd が flixlint の常駐 jar（flixlint の release の `flixlint-shim-<flix の版>.jar`）を要るようになる。
  Studio の .app にも入れる。jar が無い所は段 2 までは今の repl の経路で動き、段 3 の後は素の CLI になる（repl の経路は段 3 で消すので、2 つの道を残し続けない）。
- **版の結びつき**: エンジンの版ごとに、使う flixlint の版を 1 つ決めて固定する（flix.jar と同じ扱い）。ゲームの lint もエンジンが指す shim の jar を使う
  （今のゲームは submodule のタグから release の jar を落とす [確: Makefile の FLIXLINT_SHIM]。版が 2 か所で決まると identity が食い違い、§4.4 の 2 で常駐が 2 本になる）。
  Flix を上げる時は flixlint の対応版が先に要る。
- **lint の規則のエンジンも常駐の中で動く**: 規則（`lint/rules.flix` を組んだ jar）は `Lint.runEngine` で同じ JVM に読まれる [確: Resident.scala の engine]。
  規則は事実から違反を返す純粋な関数なので、test のような `System.exit`・AWT/GLFW・大きな静的な状態は持たない [推: flixlint v0.7 の設計 1.5 の前提]。
  無限ループは起こりうるので、1 回の走行の上限（§4.4 の 3）で止める。
- **test を入れない（決めた事 2）**: `Bootstrap.test` はゲームのコードを常駐の JVM で動かす。テストの無限ループ・`System.exit`・静的な状態・AWT/GLFW の初期化・
  1 回で数百 MB 増えるメモリ（docs/checkd.md [確]）が、check と lint を巻き込む。形は「常駐でコンパイルしてクラスを jar に書き出し（`State.build` が
  規則のエンジンで既にしている形 [確]）、別の短い JVM で `Tester` を走らせる」。jar は検査した版（§3）の名前で置き、test の答えにも同じ版を付ける。
  秒は未測定（今の repl の `:test` 3〜4 s・素の CLI 9〜12 s [確: docs/checkd.md]）。段 T で測る。repl を残さないので、test にも古い緑の穴が残らない。
- headless-run の jar 作り（`flix build-jar` を写しのディレクトリで）も同じ常駐でコンパイルできる（flixlint の `build()` は既にそうしている [確]）が、
  ソースの集合が違う（`FgeHeadlessMain.flix` を足す）ので同じ `Flix` は使えない。範囲の外とする。

### 4.4 共有の常駐の口（check・lint・spans。refactor-tool-design §8.2 と共通の正）

今の Resident [確: flixlint main 0.6.5 の Resident.scala]: 頭は `Protocol=1`・identity・環境の設定・Lint の引数、答えは 'O'/'E'/'X' の枠。
server は 1 本の thread で、1 つ accept してその走行を終えてから次を accept する。`System.setOut` を走行ごとに差し替えるので、同時に 2 本は流せない。

1. **頼みの形（protocol 2）**: 頭に `kind`（`check` | `lint` | `spans` | `test-jar`（C-T）| `stop`）・プロジェクトの根・identity・設定・引数。
   答えの枠は 'O'/'E'/'X' に、'V'（検査した版 §3）と 'Q'（並んでいる: 前の本数・走っている物の kind・経過秒）を足す。
   Go のクライアント（checkd・refactor）は Java の `DataOutputStream` の形（`writeInt` は big endian・`writeUTF` は長さ 2 バイト＋modified UTF-8）で話す。
   頭と枠の形を flixlint の README に書き、Scala と Go の両方で同じ fixture（バイト列）を読み書きするテストを置く。
2. **鍵と identity**: 常駐は「プロジェクトの根 × identity」に 1 本。identity は「flix.jar のハッシュ・shim の jar のハッシュ」（PWD と build ディレクトリは入れない。
   build ディレクトリは走行ごとの引数）。identity の違う呼び出しは、今のように server を止めず、別の socket の別の常駐へ行く（止め合いで 1 回目の秒を毎回払わない）。
   ふだんは 3 つの呼び手が同じ jar を使うので 1 本（§4.3 の版の結びつき）。2 本になった時は予算（6）で数え、`bin/fge heavy --status` に出す。
3. **同時に来た時の順**: server は空いた時に、待っている接続を全部 accept して頭だけ読み、**check を先に 1 本**、ほかは来た順に流す。
   1 度追い越された頼みは次に必ず流す（check が続いても lint が待ち続けない）。並んでいる間は 'Q' の枠を送る（refactor の 8.3 の 5 の「前に 1 本流れています」はこれを出す）。
   走っている走行は止めない。クライアントの時間切れ（今の `checkTimeoutSec` 30 s [確: hooks.json]）は**自分の走行が始まってから**数える。並びの待ちの上限は
   1 回の走行の上限（`workTimeoutSec` 900 s [確: hooks.json] を共有の値に）で、超えた走行は server が打ち切って 'X' 4 を返す。
4. **ファイルの集まりの違いの吸い方**: コンパイルは常に `Bootstrap` の sources（src＋test）で 1 つの `Flix`。lint・spans の SRC 引数は、事実と索引を書く
   ファイルの絞りにだけ使う。どの kind も、走行の頭で §2.1 の 3〜5（読み・ハッシュ・`addSource`）を同じコードで通る（lint・spans でも `addFile` を使わない）。
5. **socket の置き場**: `<ユーザーの cache>/flixlint/<根と identity のハッシュ 16 字>.sock`（macOS は `~/Library/Caches`、Linux は `$XDG_CACHE_HOME` か `~/.cache`、
   Windows は `%LOCALAPPDATA%`）。式は flixlint の README に書き、bin/flixlint と Go のクライアントに置いて同じ fixture で一致を試す（版の式と同じ扱い）。
   Unix ソケットが使えない所（Windows 10 1803 より前・JDK 16 より前）は常駐を使わず素の道へ（TCP の口は作らない。口を 2 つ持たない）。
6. **予算と寿命**: 予算の数は flixlint に持たせず（nextcms など他のプロジェクトでも同じ flixlint を使うので）、呼び手が引数（`--heap-mb`・`--idle-minutes`）で渡す。
   エンジンの呼び手（checkd・refactor・ゲームの Makefile の lint）は `hooks.json` の `checkd` の 1 か所から引く。flixlint の既定（`MaxRAMPercentage=35`・30 分）は
   引数が無い時だけ。**今の checkd の線は共有の常駐に合わない**: `rssLimit.maxMB` 4096・`heapMinMB` 3072 [確: hooks.json] に対し、typed の走行は 4.8〜5.2 GB
   [確: Mac mini] なので、そのまま当てると typed のたびに使い捨てになる。共有の常駐の線は段 1 の RSS の実測（check だけ・check＋resolved・check＋typed の索引）から
   決め直し、`hooks.json` の値を 1 回で替える。寿命は 1 つ（今の checkd 10 分と flixlint 30 分のどちらにするかは、段 2 の daemon.log の「次の頼みまでの間」の分布で決める）。
7. **壊れた時の戻り方**（3 つの kind で同じ）: 生きている server がある時は必ず並ぶ（並びを嫌って別の JVM を立てない）。server が答えない・走行の途中で落ちた時は、
   1 回だけ立て直して流し直す。2 回目も落ちたら、check は素の CLI（`make check` の正を止めない）、lint は今の 1 回きりの JVM、refactor はログの終わり 12 行で止める。
   版が合わない（§3.1）の 3 回の後の素の CLI はこれとは別で、server は生きたまま。

---

## 5. どのゲームでも設定なしで（設計書に入れる物 4）

- ゲームの名前・ディレクトリ・Doc を常駐は知らない。決めるのは「flix.toml のあるディレクトリ」と、Flix の `ProjectFiles` と同じソースの決め（src/・test/ の .flix）だけ。
  `.claude/worktrees/` の下の .flix を拾わない今の決め（srcDirs）もこれで保たれる。
- engine_full の symlink のソースは除外をやめられる（`hasSymlinkedSources` の例外を消す）[推: 段 1 の fixture に symlink の場合を入れて確かめる]。
- OS ごとの値を持たない（`watchLag` の darwin の分岐・`catchUp` を消す）。
- **Windows**: 今は template の make check が `CHECKD := 0`、`flixBin` が Windows の起動の道（JAVA ＋ flix.jar）を知らない [確: client.go のコメント]。
  新しい常駐は `java -cp flix.jar;常駐.jar` で起こすので bash の bin/flix を通らない。Go の `net.Dial("unix", …)` と JDK の
  `UnixDomainSocketAddress` は Windows 10 1803 以上で使える [推]。使えない所は常駐を使わず素の CLI（§4.4 の 5。TCP の口は残さない）。
  パスの区切り・大文字小文字は版の式で「プロジェクトの根からの相対パスを / に直す」で揃える。
- **Linux**: ファイルの監視が即時でも 1 秒の待ちを払っていた分が消える。CI（Linux）で §6 段 1 の fixture のテストを回す。

---

## 6. 段取り（設計書に入れる物 5）

段の名前は checkd の段（C-0 など）。refactor の段（R-A など）と共通の段（共-1・共-2）を合わせた順は §6.1。

| 段 | 中身 | 効いたと言う物（測る物） |
|---|---|---|
| C-0 | **測る道具を先に作る**（製品のコードは変えない）。置き場は flixlint の `test/`（Flix の小さな fixture。ゲームに頼らない）。(a) 古い答えを数える試験: 「壊す → 0〜3000 ms のばらした間をおいて check → 赤を期待 → 直す → check → 緑を期待」を 200 回。複数ファイルの書き換え・足す・消す・名前を変える・symlink・`touch -r` で mtime を戻す・同じ大きさの書き換え・検査の途中の書き換え、を混ぜる。(b) 出力の突き合わせ: 壊し方 20 通りで、素の `flix check` と常駐の出力がバイトまで同じか（「resolved → check」の順でも流す。§4.2 の 3）。(c) 段 C-2 の基準の秒: Mac mini の internet_dungeon で、今の repl（待ち 11 s）の「1 行変えた後の check」を 10 回 | (a) を今の repl の待ち 11 s と、待ちを 0 s にした物に当て、0 s で古い緑が 1 回以上出る（試験が拾える証）。11 s での数も出す。(c) の中央値と最大を基準として表に書く（依頼主の試しの約 21 s は機械が書かれていないので基準にしない） |
| C-1 | flixlint の常駐に `check` の kind（§2.1・§3・§4.4 の 1）。版の式を Scala に置く。オプションを CLI と同じにする。前提は共-1・共-2（§6.1） | C-0 の (a) で古い答え 0 / 200、(b) で 20 / 20 一致。symlink の fixture で正しく赤と緑。版の式の fixture が 64 字まで一致。オプションを揃えた前後で、ゲームの lint の違反一覧と索引の行が一致（違えば理由を 1 行ずつ）。共有の常駐の最大 RSS を 3 通り（check だけ・check の後に resolved・check の後に typed の索引）で取り、§4.4 の 6 の線を決める |
| C-2 | エンジンの checkd を新しい常駐のクライアントにする（`CHECKD_BACKEND=server` で切り替え、既定は repl のまま）。Go の protocol 2・版の式・版の比べと retry（3 回）・素の CLI。`hooks.json` の予算の線を C-1 の実測で替える | Mac mini の internet_dungeon で「1 行変えた後の check」を 10 回: 中央値が C-0 の (c) の中央値より小さい（見込みは約 11 s [推]）。古い答え 0。retry の回数と素の CLI に落ちた回数。typed の走行の最中に check を出した時の、並びの待ちの最長（'Q' の枠の経過秒） |
| C-T | test を別の JVM へ（§4.3）。常駐で組んで版の名の jar を書き（kind `test-jar`）、短い JVM で `Tester` を走らせる。`bin/fge checkd --test` をこの道へ | fixture で、test の出力と exit が素の `flix test` と同じ（通る・落ちる・無限ループを打ち切る）。C-0 の (a) を test に当てて古い緑 0 / 200。internet_dungeon の `make test` の秒 10 回を、repl の `:test`（3〜4 s）・素の CLI（9〜12 s）[確: docs/checkd.md] と並べる |
| C-3 | 既定を新しい常駐にし、**repl を消す**（check と test の両方の repl・`watchLag`・`catchUp`・symlink の例外・`maxChecks` など repl だけの値）。Windows の template の `CHECKD := 0` を外す | repl を起こすコードが 0 行（grep の出力を貼る）。C-0 の (a) を macOS・Linux（CI）・Windows で 0 回。1 週間の daemon.log で「版が合わず捨てた答え」の数と、それが全部 retry か素の CLI で収まったか。「編集後も同じエラー」の作り直しで結果が変わった回数（0 なら消す。§3.2） |
| C-5（任意） | 保存をきっかけに裏で check を始める（ファイルの監視は始める合図だけ。§2） | 1 行変えてから答えが出るまでの秒の前後 |

- 前の版の段 4（lint を同じ `Flix` で）は、共-1 と C-1 に入った（3 つの kind が 1 つの `Flix` を使う形を最初から作る）。測る物（RSS・待ちの最長・lint の結果の一致）は C-1・C-2 へ移した。
  前の版の段 5 の「resolved の共有」は §4.2 の 3 で決め、「test の置き場」は C-T にした。
- internet_dungeon での秒は Mac mini で測る（手元の Mac では重い処理を流さない）。
- **測った事**: 3 s 待ちで 1 行変えた後の check が約 21 → 14 秒、macOS の JDK のポーリングの遅れが静かな機械で最大 1.93 s / 1.81 s（各 8 回）、
  javap の `POLLING_INTERVAL = 2`（以上、ブランチの差分のコメントと依頼主の試し。機械は書かれていない）。Flix 0.78 の `addSource`・`Bootstrap.check` の中身（javap、この作業で確かめた）。
  internet_dungeon の src＋test は 172 ファイル・3,793,692 バイトで、全部の SHA-256 が 0.13 s（shasum のプロセスの起動込み、この作業で測った）。
  レビュー 2 で読んだ物: ゲームの lint は `src test` を渡す（Makefile）・checkd の線 `rssLimit.maxMB` 4096・`heapMinMB` 3072・`checkTimeoutSec` 30・`workTimeoutSec` 900（hooks.json）・
  Resident の server は 1 本ずつ accept・`Resolved.run` は `Flix` の増分の状態に書かない（flixlint main のコード）。
- **見込みで、まだ測っていない事**: 新しい常駐での秒（約 11 s）、常駐の中のハッシュの時間（10〜20 ms）と lib/ の jar のハッシュの時間、共有した時の RSS、
  lint と check の並びの待ち、`addSource` を使う常駐の出力が CLI とバイトまで同じか、test を別の JVM で走らせた時の秒、Windows での Unix ソケット。

### 6.1 2 枚を合わせた順（refactor-tool-design §8.6 と共通の正）

| 順 | 段 | 中身 | 触るリポとファイル | 前の段と並べられるか |
|---|---|---|---|---|
| 1 | R-A ＋ C-0 | refactor の出力の約束・usages・口を作る field-to-accessor・`prepare` を消す ／ checkd の測る道具 | R-A: エンジン（fge-refactor）の `go/internal/refactor`・`go/internal/checkres`・`bin/lint-rules/refactor.json`。C-0: flixlint の `test/` | 2 つは並べてよい（ぶつかるファイル無し） |
| 2 | 共-1 | 共有の常駐の土台（§4.4 の 1〜7 のうち check 以外）＝ refactor §8.6 の段 B: protocol 2・鍵と identity・socket の式・並びと 'Q'・`addSource`・spans だけの走行も常駐へ・予算を引数で・`--spans` の `adds=arg` | flixlint の `shim/Resident.scala`・`shim/Lint.scala`・`shim/Spans.scala`・`bin/flixlint`・README。エンジンの `go/internal/refactor/config.go`・`index.go`・`go/internal/hooks`（予算を読む所を 1 回だけ足す）。ゲームの Makefile の `FLIXLINT_SHIM`（エンジンが指す jar へ） | R-A の後（`config.go`・`index.go` が同じ）。flixlint v0.7 の設計 3.4 の「Resident.scala は触らない」の行をここで直す |
| 3 | 共-2 | 依存とソースの集まりを `Bootstrap` へ・`Deps.ofRoot` を消す・オプションを CLI と同じに ＝ refactor §8.6 の段 C | flixlint の `shim/Facts.scala` | 共-1 の後（`State.facts` と `Facts.depsOf` が同じ流れ） |
| 4 | C-1 | check の kind・版の式（Scala） | flixlint の `shim/Resident.scala`（と check の新しいファイル） | 共-2 の後（`Bootstrap` が無いと出力が CLI と揃わない） |
| 5 | C-2 ＋ R-D | checkd のクライアント ／ change-case-shape・change-signature | C-2: エンジンの `go/internal/checkd`・`bin/lint-rules/hooks.json`・`docs/checkd.md`。R-D: エンジンの `go/internal/refactor` | 並べてよい（同じエンジンの別の package。`hooks.json` を触るのは C-2 だけ） |
| 6 | C-T ＋ R-E | test を別の JVM へ ／ rename・safe-delete・move-fields | C-T: flixlint の Resident（`test-jar`）・エンジンの `go/internal/checkd`。R-E: エンジンの `go/internal/refactor` | 並べてよい |
| 7 | C-3 | repl を消す | エンジンの `go/internal/checkd`・template の Makefile | C-T の後 |
| 8 | R-F | v0.7 の段 3 が出たら `--spans` を層 3 へ | flixlint の `shim/Spans.scala` | v0.7 の後 |

- flixlint の変更（共-1・共-2・C-1・C-T）は main に順に入れ、各々でリリースする。エンジンは使う flixlint の版を 1 つ指す（§4.3）。
- 段 A（R-A と C-0）は共有の常駐の決めに依らないので、今入ってよい。

---

## 7. 依頼主に決めてもらう事

無し（4 つは冒頭の「決めた事」に入れた）。§4.4 の 6 の寿命（10 分か 30 分か）は C-2 の記録で決める。

---

## レビュー 2 の反映（2026-10-21）

- 冒頭: 見回り役の決めた事 4 つ（flixlint の Resident で共有・test は別の JVM・3 秒の待ちは入れない・途中の書き換えは 3 回まで retry）を書き、§0・§4.3・§6・§7 をそれに合わせた。
- 冒頭: 作業の土台を checkd-wait の未コミットの差分でなく、エンジンの main にした（3 秒の待ちを入れないので）。
- §2.1: 依存とソースの集まりを `Bootstrap` から取るとし、refactor §8.1 の A と同じ物を共-2 で 1 回だけ作るとした。lib/ の jar のハッシュの秒を未測定に足した。
- §2.1: オプションを CLI に揃えると同じ `Flix` を使う lint の事実が変わりうるので、C-1 で違反一覧と索引の一致を見るとした。
- §3.2: 「編集後も同じエラーなら作り直す」を残すだけでなく、効いた回数を数え、1 週間 0 回なら C-3 で消すとした。
- §4.1: 常駐の中に規則のエンジンの `Flix` と class loader も居る事、ゲームの lint は resolved で増分の得が無い事を足した。
- §4.2: 「lint は src だけ」は誤り（ゲームの lint は既に `src test` を渡している [確]）。コンパイルの集まりを `Bootstrap` の sources にし、引数は出力の絞りだけとした。
- §4.2: resolved を別の `Flix` で流す案をやめた（`Resolved.run` は増分の状態に書かない [確: コード]）。resolved → check の順の出力の突き合わせを C-0 に足した。
- §4.3: jar が無い所の repl の経路は C-3 で消す（2 つの道を残し続けない）。ゲームの lint もエンジンが指す shim の jar を使い、版の源を 1 つにするとした。
- §4.3: 規則のエンジンも同じ JVM で動く事と、無限ループは走行の上限で止める事を足した。test は「常駐で jar を書き、別の JVM で Tester」に決め、repl を残さないとした。
- §4.4（新）: 共有の常駐の口（protocol 2 の kind と枠・鍵と identity・check を先に 1 本で追い越しは 1 回まで・時間切れは自分の走行から数える・集まりの吸い方・socket の式・予算は呼び手の引数・壊れた時の戻り方）を、refactor §8.2 と共通の正として 1 か所に書いた。
- §4.4: 今の checkd の線（maxMB 4096）は typed の 4.8〜5.2 GB に合わないので、C-1 の RSS の実測で決め直すとした。
- §5: Windows で TCP 127.0.0.1 に落とす道をやめた（口を 2 つ持たない）。
- §6: 段 0 の (c)（混んだ機械のポーリングの遅れ）を消し、C-2 の基準の秒を同じ機械で取り直す (c) に替えた。C-2 の物差しに「基準より小さい」の比べを付けた。
- §6: test を別の JVM へ移す C-T を C-3 の前に足し、C-3 で repl を全部消す（完了は grep で 0 行）とした。前の段 4・5 の行き先を書いた。
- §6.1（新）: 2 枚を合わせた順と、触るリポとファイル、並べられる段を書いた。
- 言葉: 「名乗り」を「identity（身元）」、「記憶」を「メモリ」、「見回り」を「ポーリング」、「道連れ」を「巻き込む」にした。
