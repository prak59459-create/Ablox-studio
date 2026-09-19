import Foundation

/// The Japanese translations, keyed by the English original.
///
/// One catalogue for both apps. Ablox and Ablox Studio share the design
/// system, the project store, the block vocabulary and every message the
/// networking layer produces, so splitting the table would mean deciding for
/// each string which half it belongs to — and getting that wrong shows up as a
/// screen in the wrong language. The handful of entries only one app uses cost
/// a few kilobytes and nothing else.
///
/// ## Rules for entries
///
/// - The key is the exact English string passed to `L(...)`.
/// - `{}` marks a value filled in at runtime. Both languages must have the
///   same number of them, and in an order that makes sense in that language —
///   `LocalizationTests` checks the count, not the order.
/// - Japanese UI text omits the trailing full stop that English sentences take
///   in prose, but keeps `。` in anything that reads as a sentence.
///
/// Stored as an array of pairs rather than a dictionary literal on purpose: a
/// repeated key in a dictionary literal is a *runtime* crash, and this table is
/// too long to trust to eyes. Built with `uniquingKeysWith`, so a duplicate is
/// a failing test instead of a crash on someone's iPad.
public enum Strings {

    public static let japanese: [String: String] =
        Dictionary(entries.map { ($0.0, $0.1) }, uniquingKeysWith: { first, _ in first })

    /// Exposed so the tests can see duplicates, which the dictionary hides.
    public static let entries: [(String, String)] = coreEntries + clientEntries + studioEntries + guideEntries

    // MARK: - Shared vocabulary

    /// Block shapes, materials, behaviours, parts, sounds, and everything the
    /// networking and validation layers say. Used by both apps.
    static let coreEntries: [(String, String)] = [
        // Languages
        ("Match the iPad", "iPadに合わせる"),

        // BlockShape
        ("Box", "四角"),
        ("Sphere", "球"),
        ("Cylinder", "円柱"),
        ("Cone", "円すい"),
        ("Plane", "板"),

        // BlockMaterial
        ("Plastic", "プラスチック"),
        ("Metal", "金属"),
        ("Glass", "ガラス"),
        ("Neon", "ネオン"),
        ("Matte", "つや消し"),

        // BlockBehavior — displayName
        ("None", "なし"),
        ("Spawn Point", "スタート地点"),
        ("Checkpoint", "チェックポイント"),
        ("Hazard", "危険ブロック"),
        ("Collectible", "アイテム"),
        ("Goal", "ゴール"),
        ("Trigger", "トリガー"),
        ("Bouncy", "トランポリン"),
        ("Disappearing", "消えるゆか"),
        ("Teleporter", "ワープ"),

        // BlockBehavior — guidance
        ("Ordinary scenery. Players can stand on it and nothing else happens.",
         "ふつうのブロック。乗れるだけで、ほかには何も起きません。"),
        ("Players start on top of this block.",
         "プレイヤーはこのブロックの上からスタートします。"),
        ("Touching it sets where the player respawns. Players walk through it.",
         "さわると復活地点がここになります。すり抜けられます。"),
        ("Touching it sends the player back to their last checkpoint.",
         "さわると直前のチェックポイントまで戻されます。"),
        ("Each player can collect it once. Players walk through it.",
         "ひとり1回だけ取れます。すり抜けられます。"),
        ("Touching it ends the round for everyone.",
         "さわると全員のラウンドが終わります。"),
        ("Does nothing by itself — add a rule that listens for it.",
         "これ単体では何も起きません。ルールを足して使います。"),
        ("Launches anyone who lands on it. A trampoline.",
         "乗った人を上に打ち上げます。トランポリンです。"),
        ("Vanishes shortly after it is stepped on, then comes back.",
         "踏まれてすぐ消えて、しばらくすると戻ってきます。"),
        ("Moves the player to another block. Players walk through it.",
         "プレイヤーを別のブロックへ移動させます。すり抜けられます。"),

        // PresetKind — displayName
        ("Block", "ブロック"),
        ("Platform", "足場"),
        ("Pillar", "柱"),
        ("Ramp", "坂"),
        ("Orb", "コイン"),
        ("Lava", "溶岩"),
        ("Spawn", "スタート"),

        // PresetKind — guidance
        ("A plain 2×1×2 box. The everyday building material.",
         "ふつうの2×1×2の箱。いちばんよく使う材料です。"),
        ("A wide, thin 6×0.5×6 slab. Floors and floating islands.",
         "広くて薄い6×0.5×6の板。床や浮島に。"),
        ("A tall thin cylinder, 4 high. Posts, columns, poles.",
         "高さ4の細い円柱。柱や棒に。"),
        ("A long box already tilted 25°, so players can walk up it.",
         "最初から25°傾いた細長い箱。そのまま登れます。"),
        ("A glowing yellow sphere worth 10 points, collectible once per player.",
         "光る黄色い球。10ポイントで、ひとり1回だけ取れます。"),
        ("A flat slab of lava. Touching it sends players back to their checkpoint.",
         "平たい溶岩。さわるとチェックポイントまで戻されます。"),
        ("A green pad that saves where a player respawns.",
         "復活地点を記録する緑のパッド。"),
        ("A purple glass gate. Touching it ends the round.",
         "紫のガラスのゲート。さわるとラウンドが終わります。"),
        ("A cyan pad players start on. Every world needs at least one.",
         "プレイヤーがスタートする水色のパッド。ワールドに最低1つ必要です。"),

        // SoundCue
        ("Collect", "アイテム取得"),
        ("Checkpoint reached", "チェックポイント"),
        ("Hurt", "ダメージ"),
        ("Bounce", "バウンド"),
        ("Teleport", "ワープ"),
        // SoundCue's "Goal" is the same word as BlockBehavior's and is
        // translated once, above — a second row here would be a duplicate key.
        ("Player joined", "参加"),
        ("Player left", "退出"),
        ("Tick", "カチッ"),
        ("Error", "エラー"),

        // DisconnectReason
        ("You left the world.", "ワールドから出ました。"),
        ("The host closed the world.", "ホストがワールドを閉じました。"),
        ("Could not connect — check the room code is the same on both iPads.",
         "接続できませんでした。両方のiPadで部屋コードが同じか確認してください。"),
        ("That iPad is running a different version of Ablox. Update both to play together.",
         "そのiPadのAbloxはバージョンが違います。一緒に遊ぶには両方を更新してください。"),
        ("That world is full.", "そのワールドは満員です。"),
        ("Lost connection to the host.", "ホストとの接続が切れました。"),
        ("The host stopped responding.", "ホストが応答しなくなりました。"),
        ("Disconnected.", "切断されました。"),
        ("Reconnecting…", "再接続しています…"),
        ("Reconnecting… ({} of {})", "再接続しています…（{}/{}）"),

        // Editor tools
        ("Select", "選択"),
        ("Move", "移動"),
        ("Rotate", "回転"),
        ("Scale", "拡大縮小"),

        // Validation
        ("{} points at a parent that no longer exists.", "{} の親ブロックがもう存在しません。"),
        ("{} has a zero scale component and will be invisible.", "{} は大きさが0の軸があり、見えなくなります。"),
        ("{} is part of a parent cycle.", "{} は親子関係が循環しています。"),
        ("Rule “{}” refers to a block that no longer exists.",
         "ルール「{}」が、もう存在しないブロックを指しています。"),
        ("No spawn point — players will start above the origin.",
         "スタート地点がありません。プレイヤーは原点の上から始まります。"),

        // Shared between both apps' lobbies
        ("Cancel", "キャンセル"),
        ("Create", "作成"),
        ("Delete", "削除"),
        ("Duplicate", "複製"),
        ("Done", "完了"),
        ("Join", "参加"),
        ("Name", "名前"),
        ("OK", "OK"),
        ("Off", "オフ"),
        ("Room code", "部屋コード"),
        ("Start from", "テンプレート"),
        ("My World", "マイワールド"),
        ("Update needed", "更新が必要"),
        ("Build together", "みんなで作る"),
        ("Encrypted", "暗号化"),
        ("Full", "満員"),
        ("Host", "ホスト"),
        ("Part", "パーツ"),
        ("Player", "プレイヤー"),
        ("World", "ワールド"),
        ("{} · {}", "{}・{}"),

        // Project templates
        ("Obstacle Course", "アスレチック"),
        ("Blank", "空のワールド"),
        ("A floor, a spawn pad, stairs, a coin and a finish line. Tap Play and it already works.",
         "床・スタート地点・階段・コイン・ゴールつき。そのまま遊べます。"),
        ("Just a floor and a spawn point. Build from nothing.",
         "床とスタート地点だけ。ゼロから作ります。"),
    ]

    // MARK: - Ablox (the player client)

    static let clientEntries: [(String, String)] = [
        // Main menu and lobbies
        ("Worlds", "ワールド"),
        ("Play", "プレイ"),
        ("Settings", "設定"),
        ("Shop", "ショップ"),
        ("Avatar", "アバター"),
        ("New world", "新しいワールド"),
        ("Rename world", "名前を変更"),
        ("Rename", "変更"),
        ("Delete this world?", "このワールドを削除しますか？"),
        ("“{}” will be gone for good.", "「{}」は完全に消えます。"),
        ("Play them solo, or host one and let friends join from the Play tab.",
         "ひとりで遊ぶことも、ホストして友だちをプレイタブから招くこともできます。"),

        // Play lobby
        ("Play on your own", "ひとりで遊ぶ"),
        ("Join a friend's world", "友だちのワールドに参加"),
        ("Join world", "ワールドに参加"),
        ("Nearby worlds", "近くのワールド"),
        ("NEARBY MULTIPLAYER", "近くのマルチプレイ"),
        ("Can't search for iPads", "近くのiPadを探せません"),
        ("Could not join", "参加できませんでした"),
        ("Hosted by {}", "ホスト: {}"),
        ("The host's iPad shows this code.", "ホストのiPadに表示されているコードです。"),
        ("Hosts appear here automatically over Bonjour. Type the room code they show you and the connection is encrypted end to end.",
         "ホストはBonjourで自動的にここに出てきます。相手が見せている部屋コードを入力すると、通信は端末間で暗号化されます。"),

        // In game
        ("Players", "プレイヤー"),
        ("Scoreboard", "スコア"),
        ("Chat", "チャット"),
        ("Say something…", "メッセージを入力…"),
        ("Just you so far.", "まだあなただけです。"),
        ("ROOM CODE", "部屋コード"),
        ("Room code {}", "部屋コード {}"),
        ("Leave world", "ワールドから出る"),
        ("Leave", "出る"),
        ("Back to menu", "メニューに戻る"),
        ("Disconnected", "切断"),
        ("Unmute everyone ({})", "全員のミュートを解除（{}）"),
        ("{}ms", "{}ms"),

        // Controls
        ("Jump", "ジャンプ"),
        ("Camera", "カメラ"),
        ("Movement stick", "移動スティック"),

        // Avatar customiser
        ("Display name", "表示名"),
        ("Colours", "色"),
        ("Hat", "ぼうし"),
        ("Height", "身長"),
        ("Surprise me", "おまかせ"),
        ("This is how you appear in everyone else's world.",
         "ほかの人のワールドでは、この見た目で表示されます。"),

        // Shop
        ("Category", "カテゴリ"),
        ("Yours", "所持中"),
        ("To unlock", "未所持"),
        ("coins", "コイン"),
        ("earned all time", "これまでの合計"),
        ("Earn coins by collecting and finishing rounds, then unlock new colours and hats.",
         "アイテムを集めたりラウンドをクリアするとコインが貯まり、新しい色やぼうしと交換できます。"),

        // Settings
        ("Controls", "操作"),
        ("Movement", "移動"),
        ("Network", "ネットワーク"),
        ("About", "このアプリについて"),
        ("Language", "言語"),
        ("Sound effects", "効果音"),
        ("Haptics", "触覚フィードバック"),
        ("Joystick on the right", "スティックを右側に"),
        ("Invert camera up/down", "カメラの上下を反転"),
        ("Camera sensitivity", "カメラ感度"),
        ("Reset", "リセット"),
        ("Controls, feel, and what Ablox is doing on your network.",
         "操作・感触と、Abloxがネットワークで行っていることの説明です。"),
        ("These change how your own avatar feels. The world's own gravity still applies to blocks.",
         "自分のアバターの操作感だけが変わります。ブロックにはワールド側の重力がそのまま効きます。"),
        ("Ablox is a sandbox you build and play with friends in the same room. Build worlds in Ablox Studio, then host them here.",
         "Abloxは、同じ部屋にいる友だちと作って遊ぶサンドボックスです。Ablox Studioでワールドを作り、ここでホストします。"),
        ("Made with SwiftUI, RealityKit and Network.framework. No third-party code.",
         "SwiftUI・RealityKit・Network.frameworkで作られています。外部ライブラリは使っていません。"),
        ("Ablox Studio has the same setting.", "Ablox Studioにも同じ設定があります。"),
        ("Swaps the stick and the camera area. For left-handed players.",
         "スティックとカメラ領域を入れ替えます。左利きの人向けです。"),
        ("Drag down to look up.", "下にドラッグすると上を向きます。"),
        ("How far the view turns for one swipe.", "1回のスワイプで視点がどれだけ回るか。"),
        ("A tap when you collect something or hit a checkpoint.",
         "アイテムを取ったときやチェックポイントに着いたときに振動します。"),
        ("Service", "サービス"),
        ("Transport", "通信"),
        ("Discovery", "検出"),
        ("Protocol version", "プロトコル版数"),
        ("This iPad", "このiPad"),
        ("TCP over TLS 1.3, pre-shared key", "TCP + TLS 1.3（事前共有鍵）"),
        ("Bonjour, plus direct peer-to-peer", "Bonjourと直接ピアツーピア"),
        ("Ablox never sends anything to a server. Worlds and player positions travel directly between iPads on your local network, encrypted with a key derived from the room code the host shows you. Anyone who knows that code can join and can read that session's traffic, so share it only with the people you want in the world.",
         "Abloxはサーバーに何も送りません。ワールドやプレイヤーの位置は、ローカルネットワーク上のiPad間を直接やりとりされ、ホストが表示する部屋コードから作った鍵で暗号化されます。そのコードを知っている人は誰でも参加でき、そのセッションの通信を読めます。ワールドに入れたい相手にだけ伝えてください。"),

        // Controls help
        ("Drag to walk. Push all the way to run.", "ドラッグで歩きます。いっぱいまで倒すと走ります。"),
        ("Drag to look around.", "ドラッグで見回します。"),

        // Avatar and shop items
        ("Cap", "キャップ"),
        ("Crown", "王冠"),
        ("Antenna", "アンテナ"),
        ("Halo", "天使の輪"),
        ("Body", "からだ"),
        ("Head & arms", "頭と腕"),
        ("Legs & hat", "脚とぼうし"),
        ("{}, owned", "{}（所持中）"),
        ("{}, {} coins", "{}、{}コイン"),
        ("Coral", "コーラル"),
        ("Amber", "アンバー"),
        ("Sun", "サン"),
        ("Mint", "ミント"),
        ("Cyan", "シアン"),
        ("Blue", "ブルー"),
        ("Violet", "バイオレット"),
        ("Pink", "ピンク"),
        ("Chalk", "チョーク"),
        ("Concrete", "コンクリート"),
        ("Slate", "スレート"),
        ("Graphite", "グラファイト"),
        ("“{}” will be removed from this iPad. This cannot be undone.",
         "「{}」はこのiPadから削除されます。元に戻せません。"),
    ]

    // MARK: - Ablox Studio

    static let studioEntries: [(String, String)] = [
        // Project browser
        ("Your projects", "プロジェクト"),
        ("STUDIO · Build 3D worlds on iPad", "STUDIO・iPadで3Dワールドを作る"),
        ("New project", "新しいプロジェクト"),
        ("Delete this project?", "このプロジェクトを削除しますか？"),
        ("Join and edit together", "参加して一緒に編集"),
        ("Shared by {}", "共有元: {}"),

        // Toolbar
        ("Back to projects", "プロジェクト一覧に戻る"),
        ("Unsaved changes", "未保存の変更"),
        ("Grid", "グリッド"),
        ("Angle", "角度"),
        ("Grid snapping", "グリッドスナップ"),
        ("Angle snapping", "角度スナップ"),
        ("Undo", "取り消す"),
        ("Redo", "やり直す"),
        ("Frame selection", "選択に寄る"),
        ("How to make a map", "マップの作り方"),
        ("Share this project", "このプロジェクトを共有"),
        ("Sharing this project", "共有中"),
        ("Stop sharing", "共有をやめる"),
        ("Stop", "停止"),
        ("{} editing", "{}人が編集中"),
        ("Encrypted with TLS 1.3", "TLS 1.3で暗号化"),
        ("Other iPads running Ablox Studio can find this project and edit it with you. Give them the code.",
         "Ablox Studioを開いているほかのiPadが、このプロジェクトを見つけて一緒に編集できます。このコードを伝えてください。"),
        ("Sharing — room code {}", "共有中 — 部屋コード {}"),
        ("Joined {}", "{} に参加しました"),
        ("Saved", "保存しました"),
        ("Testing — tap Stop to keep building", "テスト中 — 停止を押すと編集に戻ります"),

        // Explorer
        ("Explorer", "エクスプローラ"),
        ("Find a part", "パーツを検索"),
        ("Move to top level", "最上位に移動"),
        ("Hide", "非表示"),
        ("Show", "表示"),
        ("No problems", "問題なし"),
        ("+{} more", "ほか{}件"),

        // Inspector
        ("Appearance", "見た目"),
        ("Transform", "位置・大きさ"),
        ("Physics", "物理"),
        ("Behaviour", "ふるまい"),
        ("Acts as", "種類"),
        ("Actions", "操作"),
        ("Shape", "形"),
        ("Material", "素材"),
        ("Colour", "色"),
        ("Colour all", "まとめて色を変える"),
        ("Nudge all", "まとめて動かす"),
        ("Delete all", "すべて削除"),
        ("Tags", "タグ"),
        ("coin, trap, door…", "coin, trap, door…"),
        ("A rule can listen for any block with a tag, so one rule can cover a whole group.",
         "ルールはタグでまとめて反応できるので、1つのルールでグループ全体を扱えます。"),
        ("Anchored", "固定"),
        ("Solid", "当たり判定"),
        ("Visible", "表示"),
        ("Stays put. Turn off to let it fall in Play mode.",
         "その場に固定します。オフにするとプレイ中に落ちます。"),
        ("Players can walk through it when off.", "オフにするとすり抜けられます。"),
        ("Score", "スコア"),
        ("Launch speed", "打ち上げの強さ"),
        ("Delay before it goes", "消えるまでの時間"),
        ("Time until it returns", "戻るまでの時間"),
        ("Wait between uses", "次に使えるまでの時間"),
        ("Sends you to", "移動先"),
        ("Nowhere", "なし"),
        ("Target", "移動先"),
        ("World name", "ワールド名"),
        ("Ground", "地面"),
        ("Lighting", "ライト"),
        ("Show backdrop", "背景を表示"),
        ("Gravity", "重力"),
        ("Fall limit", "落下限界"),
        ("Brightness", "明るさ"),
        ("Sun direction", "太陽の向き"),
        ("Sun height", "太陽の高さ"),
        ("Falls under gravity in Play mode", "プレイ中に重力で落ちます"),
        ("Unknown sound — nothing will play", "不明な音です。何も鳴りません"),
        ("Making a map", "マップの作り方"),
        ("A player who falls below the fall limit respawns.",
         "落下限界より下に落ちたプレイヤーは復活します。"),

        // Rules
        ("Rules", "ルール"),
        ("Add rule", "ルールを追加"),
        ("Delete rule", "ルールを削除"),
        ("Rule name", "ルール名"),
        ("When", "きっかけ"),
        ("Then", "すること"),
        ("Add action", "動作を追加"),
        ("Only once", "1回だけ"),
        ("Limits", "制限"),
        ("Sound", "音"),
        ("(deleted)", "（削除済み）"),
        ("tag", "タグ"),
        ("Within", "半径"),
        ("Every", "間隔"),

        // Triggers
        ("A player touches a block", "プレイヤーがブロックにさわったとき"),
        ("A player touches any tagged block", "プレイヤーがタグ付きブロックにさわったとき"),
        ("A player taps a block", "プレイヤーがブロックをタップしたとき"),
        ("A player comes close", "プレイヤーが近づいたとき"),
        ("The round starts", "ラウンドが始まったとき"),
        ("On a timer", "一定時間ごと"),
        ("A score is reached", "スコアに達したとき"),

        // Actions
        ("Change a block's colour", "ブロックの色を変える"),
        ("Move a block", "ブロックを動かす"),
        ("Hide a block", "ブロックを隠す"),
        ("Make a block walk-through", "ブロックをすり抜けられるようにする"),
        ("Teleport the player", "プレイヤーをワープさせる"),
        ("Award points", "ポイントを与える"),
        ("Show a message", "メッセージを表示する"),
        ("Play a sound", "音を鳴らす"),
        ("End the round", "ラウンドを終わらせる"),

        // Editor viewport
        ("Add {}", "{}を追加"),
        // Bare "Undo"/"Redo" are in the toolbar section above; these are the
        // forms that name the action being undone.
        ("Undo {}", "取り消す: {}"),
        ("Redo {}", "やり直す: {}"),
        ("Panel", "パネル"),
    ]

    // MARK: - Studio's map-making guide
    //
    // Long-form prose, kept apart from the interface strings so a translator
    // can work through it in one pass. Shown by `MapGuideSheet` and written to
    // `docs/making-maps.ja.md`.

    static let guideEntries: [(String, String)] = [
        ("# Making a map in Ablox Studio", "# Ablox Studioでマップを作る"),
        ("Studio shows this same guide in the app — the ? button in the toolbar.",
         "このガイドはアプリ内でも読めます。ツールバーの「?」ボタンです。"),
        ("Ten steps from an empty grid to something people can play. Tap a heading to open it.",
         "何もないグリッドから、人が遊べるものになるまでの10ステップ。見出しをタップすると開きます。"),

        // 1. Start a world
        ("Start a world", "ワールドを作る"),
        ("Every map is one world file. Studio keeps them for you and saves as you work.",
         "マップ1つがワールドファイル1つです。Studioが保管し、作業中に自動で保存します。"),
        ("From the project list, tap the new-project button, name the world, and pick a template.",
         "プロジェクト一覧で新規ボタンを押し、名前を付けてテンプレートを選びます。"),
        ("Obstacle Course starts you with a floor, a spawn pad, stairs, a coin and a finish line — it already works if you press Play. Blank gives you a floor and a spawn point.",
         "「アスレチック」は床・スタート地点・階段・コイン・ゴールが最初から入っていて、プレイを押せばもう遊べます。「空のワールド」は床とスタート地点だけです。"),
        ("Starting from Obstacle Course and taking things away is usually faster than starting from Blank, because the pieces are already wired up for you to copy.",
         "たいていは「アスレチック」から要らないものを消すほうが速く進みます。部品がすでに組み上がっていて、コピーして使えるからです。"),
        ("Build on the grid you land on. It is the floor, and it is not a block — you cannot select or delete it.",
         "最初に表示されるグリッドの上に作ります。これは床であってブロックではないので、選択も削除もできません。"),
        ("There is no Save button. Studio saves shortly after you stop editing, when you press Play, and when you go back to the project list.",
         "保存ボタンはありません。編集の手が止まった少しあと、プレイを押したとき、プロジェクト一覧に戻ったときに保存されます。"),
        ("The dot beside the world's name in the toolbar means there are changes not yet written. Saving is delayed on purpose: dragging a part makes an edit every frame, and writing all of them to storage would wear it out for no benefit.",
         "ツールバーのワールド名の横にある点は、まだ保存されていない変更があるという意味です。保存を遅らせているのはわざとで、パーツをドラッグすると毎フレーム編集が発生するため、その全部を書き込むとストレージを無駄に消耗させてしまうからです。"),

        // 2. Put parts in
        ("Put parts in", "パーツを置く"),
        ("The palette along the bottom of the viewport is where every part comes from.",
         "画面下のパレットが、すべてのパーツの出どころです。"),
        ("Tap a part in the palette and it lands in front of the camera.",
         "パレットのパーツをタップすると、カメラの前に置かれます。"),
        ("It is placed where you are looking at the moment you tap, not at the world origin — so aim first, then tap.",
         "置かれるのはタップした瞬間に見ている場所で、原点ではありません。先に向きを合わせてからタップします。"),
        ("The new part is selected straight away, so the Inspector on the right is already showing it.",
         "置いたパーツはすぐ選択状態になるので、右のインスペクタにそのまま表示されます。"),
        ("Tap the chevron above the palette to fold it away when you need the room.",
         "画面を広く使いたいときは、パレット上の矢印でたたむことができます。"),
        ("Parts land on the grid, so two of the same kind placed side by side line up exactly.",
         "パーツはグリッドに吸着するので、同じものを隣に置くとぴったり揃います。"),

        // 3. Move, turn, resize
        ("Move, turn, resize", "動かす・回す・大きさを変える"),
        ("Four tools in the toolbar. Pick one, then drag the part.",
         "ツールバーに4つのツールがあります。選んでからパーツをドラッグします。"),
        ("Select picks parts. Tap a part to select it; tap with two fingers to add it to the selection instead of replacing it.",
         "「選択」はパーツを選ぶツールです。タップで選択、2本指でタップすると選択に追加します（置き換えではありません）。"),
        ("Nothing is selectable in Play mode — the editing gestures are switched off there entirely.",
         "プレイ中は何も選択できません。編集用の操作がすべて無効になります。"),
        ("Move, Rotate and Scale each drag the selected parts along the ground or around their centre.",
         "「移動」「回転」「拡大縮小」は、選んだパーツを地面に沿って、または中心まわりに動かします。"),
        ("The grid button snaps position to 0.25, 0.5, 1 or 2 metres. The angle button snaps rotation to 15°, 45° or 90°. Both have an Off setting.",
         "グリッドボタンは位置を0.25・0.5・1・2メートルに吸着させます。角度ボタンは回転を15°・45°・90°に吸着させます。どちらもオフにできます。"),
        ("Off is for fine adjustment only — platforms that do not line up on the grid leave gaps a player can fall through.",
         "オフは微調整のときだけにします。グリッドに揃っていない足場は、プレイヤーが落ちる隙間を作ります。"),
        ("Undo and Redo go back through everything, including deletes.",
         "取り消しとやり直しは、削除を含めてすべての操作をさかのぼれます。"),
        ("Duplicate and Delete are in the Inspector's Actions group, and in the menu you get by pressing and holding a row in the Explorer list.",
         "複製と削除はインスペクタの「操作」にあります。エクスプローラの行を長押しして出るメニューからも使えます。"),
        ("Duplicating a group copies its children and keeps their internal parent links, so copying a whole staircase gives you a staircase, not nine loose steps.",
         "グループを複製すると子も一緒にコピーされ、親子関係も保たれます。階段をまるごとコピーすれば階段になり、バラバラの段が9個になることはありません。"),
        ("In the Explorer, drag one row onto another to make it a child. Moving the parent then moves the child with it.",
         "エクスプローラで行を別の行にドラッグすると、子にできます。親を動かすと子もついてきます。"),
        ("Group the parts you will want to copy or move as a unit before you build the second one — that is what turns one staircase into a tower.",
         "まとめてコピーしたり動かしたりするパーツは、2つめを作る前にグループにしておきます。これが階段1つを塔に変えるコツです。"),

        // 4. Make it look right
        ("Make it look right", "見た目を整える"),
        ("The Inspector on the right edits whatever is selected.",
         "右のインスペクタは、選択中のものを編集します。"),
        ("Name each part as you go. The Explorer list and every rule refer to parts by name.",
         "作りながらパーツに名前を付けます。エクスプローラもルールも、パーツを名前で指します。"),
        ("Colour and material change how a part is lit. Neon glows without needing a light; glass is see-through.",
         "色と素材で光り方が変わります。ネオンはライトがなくても光り、ガラスは透けます。"),
        ("Anchored keeps a part still. Turn it off and the part falls in Play mode.",
         "「固定」はパーツをその場に留めます。オフにするとプレイ中に落ちます。"),
        ("Almost everything you build should stay anchored. Unanchored parts are for the one crate you meant to knock over.",
         "作るものはほぼすべて固定のままにします。固定を外すのは「倒したい木箱1つ」のような場面だけです。"),
        ("Solid is what players collide with. Turn it off to walk through a part.",
         "「当たり判定」はプレイヤーがぶつかるかどうかです。オフにするとすり抜けられます。"),
        ("A part can be visible and not solid — that is how you make decoration players do not bump into.",
         "見えていて当たり判定がない、という状態も作れます。ぶつからない飾りはこうして作ります。"),

        // 5. Give parts a job
        ("Give parts a job", "パーツに役割を持たせる"),
        ("Behaviour is the no-code half of Ablox: pick one and the part does something when a player touches it.",
         "「ふるまい」はAbloxのノーコード部分です。選ぶだけで、プレイヤーがさわったときに何かが起きます。"),
        ("{} — {}", "{} — {}"),

        // 6. Tune the gimmicks
        ("Tune the gimmicks", "ギミックを調整する"),
        ("Bouncy, Disappearing and Teleporter each get their own settings under the behaviour picker.",
         "トランポリン・消えるゆか・ワープには、ふるまいの選択欄の下にそれぞれ専用の設定が出ます。"),
        ("Bouncy: launch speed, in metres per second, from 6 to 30. It starts at 14.",
         "トランポリン: 打ち上げの強さ（メートル毎秒）。6〜30で、初期値は14です。"),
        ("Speed replaces upward motion rather than adding to it, so bouncing while already rising cannot compound into an escape from the map.",
         "上向きの速度は加算ではなく置き換えです。上昇中にもう一度跳ねても速度が積み重ならないので、マップの外まで飛んでいくことはありません。"),
        ("Disappearing: how long before it goes, and how long until it comes back.",
         "消えるゆか: 消えるまでの時間と、戻ってくるまでの時間。"),
        ("Teleporter: the part it sends players to. A pad cannot target itself.",
         "ワープ: 飛ばす先のパーツ。自分自身は指定できません。"),
        ("Two pads pointing at each other make a two-way door. Pointing a pad at itself would drop the player back on the pad forever, so Studio does not offer it.",
         "2つのパッドを互いに向けると双方向の扉になります。自分自身を指すとプレイヤーが永久に同じパッドに戻り続けるので、Studioは選択肢に出しません。"),
        ("All three share a cooldown: the wait before the same part can fire again.",
         "3つとも共通で「次に使えるまでの時間」を持ちます。同じパーツがもう一度作動するまでの待ち時間です。"),
        ("The cooldown is per part and per player. It exists because a player standing on a bounce pad would otherwise be launched every single frame.",
         "この待ち時間はパーツごと・プレイヤーごとです。これがないと、トランポリンの上に立っているだけで毎フレーム打ち上げられてしまいます。"),

        // 7. Add rules
        ("Add rules", "ルールを足す"),
        ("When behaviours are not enough, the Rules tab on the left builds \"when this happens, do that\".",
         "ふるまいだけで足りないときは、左の「ルール」タブで「これが起きたら、こうする」を組み立てます。"),
        ("A rule is one trigger and any number of actions. Add a rule, pick the trigger, then add actions to it.",
         "ルールは、きっかけ1つと動作いくつかの組です。ルールを追加し、きっかけを選び、動作を足していきます。"),
        ("Triggers include touching or tapping a part, walking near one, the world starting, a repeating timer, and a score being reached.",
         "きっかけには、パーツにさわる・タップする・近づく、ワールドの開始、一定時間ごと、スコア到達があります。"),
        ("Actions can recolour or move a part, hide it, make it walk-through, teleport the player, award points, show a message, play a sound, or end the round.",
         "動作では、パーツの色を変える・動かす・隠す・すり抜けられるようにする、プレイヤーをワープさせる、ポイントを与える、メッセージを出す、音を鳴らす、ラウンドを終わらせる、ができます。"),
        ("Give a part the Trigger behaviour when you want it to do nothing on its own and only feed a rule.",
         "単体では何もせず、ルールのきっかけとしてだけ使いたいパーツには「トリガー」を設定します。"),
        ("The host decides what a rule does, not the player's iPad. That is why nobody can give themselves points by editing their own copy.",
         "ルールの結果を決めるのはホストで、プレイヤーのiPadではありません。だから手元のコピーを書き換えて自分にポイントを足す、ということはできません。"),

        // 8. Play it
        ("Play it", "遊んでみる"),
        ("The Play button swaps the editor for the game, in the same world, without leaving Studio.",
         "プレイボタンを押すと、Studioを出ないまま同じワールドがゲームに切り替わります。"),
        ("Press Play to drop in as a character. Press Stop to go back to editing.",
         "プレイを押すとキャラクターとして入り、停止を押すと編集に戻ります。"),
        ("Entering Play saves the world first, so a crash while testing cannot cost you the session's work.",
         "プレイに入る前に保存されるので、テスト中に落ちてもその日の作業は失われません。"),
        ("Play from the start every time you add a jump. A gap that looks crossable often is not.",
         "ジャンプを足したら毎回、最初から通して遊んでみます。越えられそうに見える隙間が、実は越えられないことはよくあります。"),
        ("The editing gestures are switched off in Play mode, so nothing you do as a player can move a part.",
         "プレイ中は編集操作が無効なので、プレイヤーとして何をしてもパーツは動きません。"),
        ("Watch where you land after touching a hazard — that tells you which checkpoint was actually the last one.",
         "危険ブロックにさわったあと、どこに戻されるかを見ます。実際に最後のチェックポイントがどれだったかが分かります。"),

        // 9. Build together
        ("Two iPads on the same Wi-Fi can edit one world at the same time.",
         "同じWi-Fiにいる2台のiPadで、1つのワールドを同時に編集できます。"),
        ("Tap Share. Studio shows a room code and starts advertising on the local network.",
         "共有ボタンを押すと、部屋コードが表示され、ローカルネットワークへの告知が始まります。"),
        ("On the other iPad, find the session in the list and enter the same code.",
         "もう一方のiPadで一覧からセッションを見つけ、同じコードを入力します。"),
        ("Edits flow both ways as you make them.",
         "編集はその場で双方向に反映されます。"),
        ("Joining replaces the joiner's world with the host's, including their undo history — so join before you start building, not after.",
         "参加すると、参加した側のワールドはホストのもので置き換わります。取り消し履歴も一緒に消えるので、作り始める前に参加してください。"),
        ("Everything stays on your network. Nothing is uploaded anywhere.",
         "すべてネットワーク内で完結します。どこにもアップロードされません。"),

        // 10. Before you share it
        ("Before you share it", "人に渡す前に"),
        ("A short list that catches most of what makes a map unplayable.",
         "マップが遊べなくなる原因のほとんどは、この短いリストで見つかります。"),
        ("At least one Spawn part. Without it players have nowhere to start.",
         "スタート地点を最低1つ。ないとプレイヤーが始められません。"),
        ("Studio flags this for you — a world with no spawn point is reported as a problem before a session starts.",
         "これはStudioが教えてくれます。スタート地点のないワールドは、セッション開始前に問題として報告されます。"),
        ("A checkpoint before anything that can kill, or a mistake costs the whole run.",
         "死ぬ可能性がある場所の手前にはチェックポイントを。ないと1回のミスで最初からやり直しになります。"),
        ("No part scaled to zero on any axis. It becomes invisible but still blocks players.",
         "どの軸も大きさ0のパーツを残さないこと。見えないのに、プレイヤーを止めてしまいます。"),
        ("Walk the whole route in Play mode once, start to finish, without using the editor.",
         "プレイモードで、編集を使わずに最初から最後まで一度通してみます。"),
        ("Give the world a name you will recognise in the list a month from now.",
         "1か月後に一覧で見ても分かる名前を付けておきます。"),
    ]
}
