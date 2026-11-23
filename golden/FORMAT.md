# 比對資料格式

`golden/data/` 由 `gen.sh` 產生，不手改（`docs/design.md` D5）。Dart 這邊的測試讀同一份輸入，照下面的規則產出同樣的東西，再跟這裡的檔案逐行比對。

所有 `.gz` 都是 gzip 壓縮的 UTF-8 純文字，每行以 `\n` 結尾。

## 輸入

`INPUT` 第一行是 GitHub Release 的 tag，之後是那個 release 的 `SHA256SUMS`。測試先用 `gh release download <tag>` 取得輸入並核對校驗碼，不符就失敗，不跳過。

## 第 1 層：解碼（`<tile>.decode.tsv.gz`）

每個非空的 micro-cache 一行。順序是分塊內的 25 個一度格（經度再緯度），每個一度格內依 `lonIdx` 再 `latIdx` 由小到大，跟 Java 讀檔的順序相同：

```
lonIdx <TAB> latIdx <TAB> 節點數 <TAB> 摘要
```

- `lonIdx`、`latIdx` 是絕對索引：`(經度 + 180) × divisor + i`、`(緯度 + 90) × divisor + j`。目前的分塊 `divisor` 是 32。
- 解碼時不給 way validator（每條路段都保留），也不給 waypoint matcher。`docs/design.md` D7 說明了為什麼。
- 摘要是下面「節點紀錄」位元組的 SHA-256，取前 16 個位元組，小寫十六進位。

### 節點紀錄

全部 big-endian。`int` 4 位元組、`short` 2 位元組、`byte` 1 位元組。`bytes` 是一個 `int` 長度加上那麼多位元組，沒有資料時長度為 0。

```
int lonIdx
int latIdx
int 節點數
每個節點，依 micro-cache 內的順序（id 由小到大）：
  int ilon
  int ilat
  int 轉彎限制數
  每個轉彎限制：
    short exceptions
    byte  isPositive（0 或 1）
    int   fromLon, fromLat, toLon, toLat
  short selev
  bytes 節點描述
  int   路段數
  每個路段，依讀出的順序：
    int   ilon（目標節點，已加上本節點座標）
    int   ilat
    byte  isReverse（0 或 1）
    bytes 路段描述
    bytes geometry（中間點的編碼，原樣）
```

這就是 `OsmNode.parseNodeBody2` 從 `MicroCache2` 讀出的每一個欄位，順序相同。自己連到自己的路段也要列，`parseNodeBody2` 讀到時才略過。

### 找出哪裡不同

摘要不同時，用 Java 印出那一格的內容，跟 Dart 印的比：

```
golden/gen.sh   # 先建好參考引擎與輸入
java -cp "golden/.build/classes:$(ls golden/.build/brouter/brouter-*/build/libs/*.jar | tr '\n' ':')" \
  Golden dump golden/.build/input/<release>/<tile>.rd5 <lonIdx> <latIdx>
```

## 規則的輸入（`ways.hex.gz`、`nodes.hex.gz`）

兩塊分塊裡出現過的所有路段描述與節點描述，去重複、依字串排序（`LC_ALL=C`），一行一個，小寫十六進位。

## 第 2 層：規則（`<profile>.rules.tsv.gz`）

先是 `ways.hex` 的每一行，再是 `nodes.hex` 的每一行，順序同輸入：

```
way  <TAB> 描述 <TAB> 正向 20 個值 <TAB> 反向 20 個值
node <TAB> 描述 <TAB> initialcost（nodeaccessgranted 為 false） <TAB> initialcost（為 true）
```

- 每個值是 Java `float` 的原始位元（`Float.floatToRawIntBits`），8 位小寫十六進位。
- 路段的 20 個值依 `BExpressionContextWay` 的 built-in 變數順序：costfactor、turncost、uphillcostfactor、downhillcostfactor、initialcost、nodeaccessgranted、initialclassifier、trafficsourcedensity、istrafficbackbone、priorityclassifier、classifiermask、maxspeed、uphillcost、downhillcost、uphillcutoff、downhillcutoff、uphillmaxslope、downhillmaxslope、uphillmaxslopecost、downhillmaxslopecost。
- 節點 context 的 `evaluate` 第一個參數是 nodeaccessgranted，路徑搜尋時依抵達的路段決定，所以兩種都記。
- 規則檔以 `global` 為唯讀 context 解析，不帶額外參數。
- 不用結果快取，每一行都從頭算。兩份規則的節點 context 都沒有讀路段變數，所以節點那幾行跟前面算過什麼無關。

### 規則沒用到的運算子（`ops.tsv.gz`）

`hiking-mountain` 與 `trekking` 都沒用到 sub、divide、min、max、xor、not、equal 與 `v:`。`golden/ops.brf` 是用到這些運算子的小規則，跟上面一樣跑過 `ways.hex` 與 `nodes.hex` 的每一行（context 設定、`global` 唯讀、不用結果快取都相同），但只記每個變數的 CRC32，不逐行記：

```
way  <TAB> forward 或 reverse <TAB> 變數名 <TAB> CRC32
node <TAB> false 或 true <TAB> initialcost <TAB> CRC32
```

- 先是正向 20 行、再是反向 20 行，變數順序同上；最後兩行是節點，第二欄是 nodeaccessgranted。
- CRC32 是 `btools.util.Crc32` 算在那個變數依輸入順序排列的值上，每個值是 `Float.floatToRawIntBits` 的 4 位元組 big-endian；8 位小寫十六進位。

## 第 0 層：底層工具（`util.tsv.gz`）

util 的移植對 Java 版逐筆比對。每行第一欄是種類，輸入與結果都寫在同一行，Dart 不需要重現 `java.util.Random`。double 一律寫成 16 位十六進位的原始位元（`Double.doubleToRawLongBits`）。

| 種類 | 欄位 |
|---|---|
| `sin`、`cos`、`exp` | x、`StrictMath` 的結果 |
| `atan2` | y、x、結果 |
| `geo` | 三個點的 lon/lat 整數座標、距離、角度；`CheapRuler.distance`（前兩點）、`destination` 的 lon 與 lat（第一點、距離、角度）、`CheapAngleMeter.calcAngle` 與它的 cos、`getDirection`（前兩點） |
| `dir` | b1、b2、`getDifferenceFromDirection(b1, b2)`、`normalize(b1)` |
| `crc` | 位元組（十六進位）、`Crc32.crc`（8 位十六進位） |
| `varlen` | v、`writeVarLengthSigned(v)` 接著 `writeVarLengthUnsigned(v)` 寫出的位元組、讀回的 signed 與 unsigned 值（v 很大時 Java 的 signed 編碼會溢位，讀回的值照 Java 記） |
| `ints` | `writeInt`、`writeLong`、`writeShort`、`writeByte`、`writeBoolean` 的輸入，寫出的位元組，`readInt`、`readLong`、`readShort`、`readByte`、`readBoolean` 讀回的值 |
| `inject` | 前導位元組、資料、`writeSizePlaceHolder` 後寫資料再 `injectSize` 得到的位元組；資料長度跨過 1、2、3 位元組的長度前綴 |
| `bitread` | 64 個隨機位元組、讀取序列（`d<count>:<值>` 是 decodeBits，`r<count>:<值>` 是 decodeBitsReverse） |
| `bits` | 操作序列（`v<值>` 是 encodeVarBits、`b<max>:<值>` 是 encodeBounded、`0`／`1` 是 encodeBit，以逗號分隔）、編出的位元組 |

三角函數的輸入包含 `CheapRuler` 快取的 1,800 個緯度、隨機值、π/2 倍數附近、以及 0、−0、NaN、無限大等邊界；`encodeBounded` 的 max 小於 2^30，再大的話 Java 的迴圈不會結束。

## 第 3 層：路線（`routes.tsv.gz`）

案例在 `golden/routes.tsv`：只用公開的登山口、山頂、山屋與地標，不用任何人的航跡或位置。每個案例各用 `hiking-mountain` 與 `trekking` 算一次，每次都新建一個用預設 `RoutingContext` 的 `RoutingEngine`，跟一般請求一樣。

經緯度換成整數座標的方式跟 BRouter 的伺服器相同：`180000000 + (int) (經度 × 1e6 + 0.5)`，緯度用 90000000。

每次路線先一行 `route`，成功時接著每個軌跡點一行 `node`：

```
route <TAB> 案例 <TAB> 規則 <TAB> 起點 ilon <TAB> 起點 ilat <TAB> 終點 ilon <TAB> 終點 ilat <TAB> ok <TAB> distance <TAB> ascend <TAB> plainAscend <TAB> cost <TAB> energy <TAB> getTotalSeconds() <TAB> 點數
route <TAB> 案例 <TAB> 規則 <TAB> 起點 ilon <TAB> 起點 ilat <TAB> 終點 ilon <TAB> 終點 ilat <TAB> error <TAB> 錯誤訊息
node  <TAB> ilon <TAB> ilat <TAB> selev <TAB> cost <TAB> time <TAB> energy
```

- distance、ascend、plainAscend、cost、energy 是 `OsmTrack` 的 int 欄位。
- `node` 的 time 與 energy 是 float 的原始位元，8 位十六進位。
- 錯誤也是標準答案：Dart 版在同樣的案例要回同樣的錯誤，例如起點在海上太遠、從離島出發找不到路。
