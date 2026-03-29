# vvenc `Slice` 类分析

## 1. 类定位

`Slice` 是 vvenc 中描述“当前切片编码语义和参考关系”的核心数据对象。

它不是：

- `EncSlice` 那种负责调度 CTU 编码的执行类
- 也不是 `Picture` 那种承载整帧像素和编码结果的帧对象

它更像是：

- 当前 slice 的参数集合
- 当前 slice 的参考图管理器
- 当前 slice 的刷新语义、RPL、WP、滤波开关等状态载体

一句话说，`Slice` 负责回答：

- 这是什么 slice
- 它依赖哪些参考图
- 当前参考图列表怎么构造
- 参考图在 IRAP / CRA / DRAP 语义下如何约束和标记

## 2. 在编码链路中的位置

`Slice` 位于 `Picture`、参数集和编码执行器之间。

一个简化关系可以写成：

```text
ParameterSetManager
  -> SPS / PPS / APS / PicHeader
  -> Picture
     -> Slice
        -> EncSlice / EncCu / InterSearch / CABACWriter
```

从调用上看：

- `Picture` 持有一个或多个 `Slice`
- `EncSlice` 读取 `Slice` 中的 QP、RPL、滤波标志、lambda 等信息
- `InterSearch`、`EncCu`、`CABACWriter` 在编码中频繁访问 `Slice`

因此 `Slice` 是一份“跨多个编码模块共享的当前 slice 上下文”。

## 3. `Slice` 和 `EncSlice` 的区别

这是最容易混淆的一点。

### 3.1 `Slice`

`Slice` 是数据与语义对象，重点是：

- slice type
- NALU type
- RPL / 参考图列表
- 参考图可达性与刷新规则
- QP、lambda、去块 / SAO / ALF / WP 等参数

### 3.2 `EncSlice`

`EncSlice` 是编码执行与调度对象，重点是：

- 驱动 CTU 编码
- 调度线程
- 组织后处理
- 写 slice 数据

可以简单理解为：

- `Slice` = “这个 slice 是什么”
- `EncSlice` = “这个 slice 怎么编码”

## 4. 类结构与关键成员

`Slice` 的成员很多，但可以按职责分成几组。

### 4.1 基本标识与 slice 类型

```cpp
int              ppsId;
int              poc;
vvencNalUnitType nalUnitType;
SliceType        sliceType;
uint32_t         nuhLayerId;
uint32_t         TLayer;
```

这些成员决定：

- 当前 slice 属于哪个 `PPS`
- 当前图像的 `POC`
- NAL 单元类型是否为 `IDR`、`CRA`、`RASL`、`RADL` 等
- 是 `I/P/B` 中哪一种 slice
- 所在 layer 和 temporal layer

这是整个 `Slice` 语义的基础。

### 4.2 参数集与所属对象引用

```cpp
const VPS*   vps;
const DCI*   dci;
const SPS*   sps;
const PPS*   pps;
Picture*     pic;
PicHeader*   picHeader;
```

这里体现出 `Slice` 不是孤立对象，而是把当前 slice 绑定到：

- 参数集
- 所属 `Picture`
- 当前 `PicHeader`

也就是说，`Slice` 是 picture 级和 bitstream 级语义在当前编码单元上的汇合点。

### 4.3 参考图列表相关成员

```cpp
const ReferencePictureList* rpl[2];
ReferencePictureList        rplLocal[2];
int                         rplIdx[2];
int                         numRefIdx[2];

Picture*                    refPicList[2][MAX_NUM_REF+1];
int                         refPOCList[2][MAX_NUM_REF+1];
bool                        isUsedAsLongTerm[2][MAX_NUM_REF+1];
int                         list1IdxToList0Idx[MAX_NUM_REF];
```

这是 `Slice` 最核心的一组成员。

它们分别表示：

- 当前 slice 实际使用的 `RPL`
- 若 slice header 中显式带本地 RPL，则用 `rplLocal`
- 当前生效的参考图数量
- 实际解析/绑定后的参考图指针
- 对应参考图 POC
- 是否按长期参考处理
- `L1 -> L0` 的索引映射关系

可以把它理解为两层：

- `RPL` 是“语法层参考描述”
- `refPicList` 是“运行时实际参考图对象”

### 4.4 刷新和恢复相关状态

```cpp
int              lastIDR;
int              prevGDRInSameLayerPOC;
int              associatedIRAP;
vvencNalUnitType associatedIRAPType;
bool             pendingRasInit;
bool             enableDRAPSEI;
bool             useLTforDRAP;
bool             isDRAP;
int              latestDRAPPOC;
```

这组成员用于表达：

- 当前图像与哪一个 IRAP / CRA / GDR / DRAP 相关联
- 恢复点和刷新边界如何约束参考图
- 是否存在延迟生效的刷新

这部分不是普通 inter 编码流程中最显眼的部分，但它决定了参考图能不能合法使用，属于高语义密度状态。

### 4.5 编码控制参数

```cpp
int      sliceQp;
double   lambdas[MAX_NUM_COMP];
bool     depQuantEnabled;
bool     signDataHidingEnabled;
bool     tsResidualCodingDisabled;
bool     cabacInitFlag;
SliceType encCABACTableIdx;
```

这些参数被编码器其他模块直接消费：

- `sliceQp` 决定基础量化强度
- `lambdas` 决定 RD 代价权重
- `cabacInitFlag` 和 `encCABACTableIdx` 影响 CABAC 表选择
- 若干残差工具开关决定块级编码行为

### 4.6 环路滤波和增强工具开关

```cpp
bool saoEnabled[MAX_NUM_CH];
bool deblockingFilterDisable;
bool deblockingFilterOverride;
int  deblockingFilterBetaOffsetDiv2[MAX_NUM_COMP];
int  deblockingFilterTcOffsetDiv2[MAX_NUM_COMP];

bool alfEnabled[MAX_NUM_COMP];
APS* alfAps[ALF_CTB_MAX_NUM_APS];
int  numAps;
std::vector<int> lumaApsId;
int  chromaApsId;
bool ccAlfCbEnabled;
bool ccAlfCrEnabled;
```

这一组成员负责携带 slice 级滤波相关语义：

- deblocking
- SAO
- ALF / CCALF

这些信息在 `EncSlice`、滤波模块和码流写出阶段都会使用。

### 4.7 加权预测相关成员

```cpp
WPScalingParam weightPredTable[2][MAX_NUM_REF][MAX_NUM_COMP];
WPACDCParam    weightACDCParam[MAX_NUM_COMP];
```

这部分负责 weighted prediction 参数。

对 inter 编码来说，这组数据影响：

- 参考像素在预测阶段如何加权
- 后续 motion compensation 的实际像素生成方式

## 5. 生命周期

### 5.1 构造函数

`Slice::Slice()` 会初始化：

- 默认 `nalUnitType` / `sliceType`
- 各类指针为空
- `rpl` 和参考图列表为空
- `list1IdxToList0Idx` 为 `-1`
- WP 参数恢复为默认值

它做的是“干净初始化”，并不构造真实参考图关系。

### 5.2 `resetSlicePart()`

这个函数用于重置 slice 的部分运行时状态，主要包括：

- `colFromL0Flag`
- `colRefIdx`
- `checkLDC`
- `biDirPred`
- `symRefIdx`
- `cabacInitFlag`
- `substreamSizes`
- `lambdas`
- `alfEnabled`
- `sliceMap`

可以理解为：当进入一个新的 slice 编码前，把上一轮运行过程中残留的局部状态清掉。

## 6. 参考图管理

`Slice` 最重要的职责之一，就是把 RPL 变成真正可用的参考图列表。

### 6.1 `constructRefPicList()`

这是参考图列表构造主入口。

逻辑可以概括为：

```text
如果是 I slice:
  refPicList 为空
否则:
  对 L0/L1 的每个活跃参考项:
    如果是短期参考:
      用 poc + deltaPoc 找 Picture
    如果是长期参考:
      用 xGetLongTermRefPic() 按 LT 规则找 Picture
    必要时扩展边界
    写入 refPicList / isUsedAsLongTerm
```

这个函数完成的是从“RPL 语义”到“真实 `Picture*`”的绑定。

### 6.2 `xGetLongTermRefPic()`

这个私有函数专门做长期参考图查找。

它会：

- 按 `bitsForPOC` 处理 POC 周期
- 根据是否携带 MSB 决定匹配方式
- 在 `PicList` 中查找对应长期参考图

长期参考图和短期参考图在匹配逻辑上不同，这就是为什么单独抽出这个函数。

### 6.3 `setRefPOCList()`

这个函数把当前 `refPicList` 里的 `Picture` 对象 POC 写入 `refPOCList`。

用途很直接：

- 为后续运动搜索、collocated reference、比特写出等路径提供轻量 POC 访问

### 6.4 `setList1IdxToList0Idx()`

这个函数建立：

```text
L1 的某个参考索引
-> 是否能映射到同 POC 的 L0 参考索引
```

在 B slice 中，这个映射很有价值，因为：

- 某些双向预测快速路径需要知道两侧是否引用同一参考图
- inter 搜索里常利用这个关系减少重复 motion estimation

### 6.5 `updateRefPicCounter()`

它会对当前活跃参考图的 `refCounter` 做统一增减。

这是典型的引用计数型运行时维护逻辑，用于管理参考图在编码流程中的占用状态。

## 7. 参考图合法性与可用性检查

### 7.1 `checkAllRefPicsAccessible()`

这个函数检查：

- 当前 slice 所依赖的所有参考图，是否都已经进入可访问处理列表

### 7.2 `checkAllRefPicsReconstructed()`

这个函数检查：

- 当前 slice 所依赖的所有参考图，是否都已经完成重建

这两个检查分别对应：

- 调度层面的“能不能访问”
- 数据层面的“是否真的可用”

### 7.3 `isRplPicMissing()`

这是更强的一层检查。

它会逐项检查 RPL 中要求的短期 / 长期参考图是否真实存在于 `PicList` 中，并考虑：

- 长期参考图 POC 周期
- `DRAP` 约束
- future IDR-no-LP 限制

若缺失，会返回缺失的 POC。

这说明 `Slice` 不只是保存 RPL，还负责验证它在当前 DPB 上是否可实现。

## 8. 刷新语义与参考图标记

这一部分是 `Slice` 里很关键但容易被忽略的职责。

### 8.1 `checkCRA()`

这个函数处理 `CRA/IDR` 相关状态：

- 更新 `pocCRA`
- 更新 `associatedIRAPType`
- 检查当前 RPL 是否违反 CRA 之前不可引用的约束

### 8.2 `setDecodingRefreshMarking()`

这个函数负责在遇到 `IDR` / `CRA` 等刷新点后，对 DPB 中图片做“是否继续作为参考”的标记。

逻辑大意是：

- `IDR` 时清除旧参考
- `CRA` 时延迟刷新
- 当刷新条件生效后，把不再允许使用的旧图标成 `unused for reference`

因此它本质上在维护：

- 哪些旧图还能继续做参考
- 哪些必须从参考语义上失效

### 8.3 `applyReferencePictureListBasedMarking()`

这个函数按当前 `RPL0/RPL1` 反向更新 `PicList`：

- 如果某张图已不在当前参考图集合中
- 且满足层级/时序条件
- 就把它标记为不再参考

这等于把“当前 slice 的参考需求”反映回 DPB 状态。

## 9. 与输出顺序和 IRAP 约束的关系

### 9.1 `checkLeadingPictureRestrictions()`

这个函数检查：

- `RASL` / `RADL` / `CRA` / `IDR` 等图像之间的输出顺序是否合法
- 当前图像与 `associatedIRAP` 的关系是否满足规范限制

也就是说，`Slice` 不光管“参考图能不能用”，还管“这种 NAL 类型组合是否合法”。

### 9.2 `isStepwiseTemporalLayerSwitchingPointCandidate()`

这个函数检查当前图像是否满足逐级 temporal switching point 条件。

核心依据是：

- 参考缓冲中是否存在 `TLayer >= 当前 TLayer` 的其它有效参考图

这类函数体现出 `Slice` 是时序结构语义的承载体，而不仅是一个局部编码参数容器。

## 10. 双向预测和 collocated 参考相关

### 10.1 `setSMVDParam()`

这个函数会在满足条件时为 `SMVD` 相关快速路径设置：

- `biDirPred`
- `symRefIdx[0/1]`

其核心思想是：

- 从 `L0/L1` 中找一对前后向对称参考图
- 若存在，就记录这对索引

这直接影响后续 inter 编码工具是否可用。

### 10.2 `checkColRefIdx()`

这个函数检查：

- 同一张已编码图片中的不同 slices，其 collocated reference index 是否一致

这属于 slice 间一致性约束检查。

## 11. 本地 RPL 构造

### 11.1 `createExplicitReferencePictureSetFromReference()`

这是 `Slice` 里比较复杂的一个函数。

它的目标是：

- 从原始 `RPL0/RPL1` 出发
- 结合当前 `PicList` 中实际存在且合法的参考图
- 构造当前 slice 头可显式携带的本地 `RPL`

它会处理：

- 可用参考筛选
- `DRAP` 相关附加约束
- L0/L1 之间互相补足参考项
- 同号 deltaPoc 的限制

最终结果会写入：

- `rplLocal[0/1]`
- `rpl[0/1]`
- `rplIdx[0/1] = -1`

这说明 `Slice` 还能在运行时“重写”当前 slice 实际使用的参考图集合，而不只是被动读取 SPS/PPS 里的 RPL。

## 12. 加权预测与裁剪范围

### 12.1 `resetWpScaling()` / `getWpScaling()`

这两个函数分别负责：

- 初始化默认的 WP 参数
- 给其他模块提供当前参考图的加权参数访问

### 12.2 `setDefaultClpRng()`

它根据 `SPS` 初始化 `clpRngs`。

后续预测、重建、滤波等路径都可能用到这个裁剪范围，所以这也是 `Slice` 作为“共享状态对象”的一部分。

## 13. 其他实用接口

`Slice` 还有一些很常用的辅助接口：

- `isIntra()`
- `isInterP()`
- `isInterB()`
- `getRapPicFlag()`
- `getIdrPicFlag()`
- `isIRAP()`
- `getMinPictureDistance()`

这些接口本身不复杂，但在编码器很多热点路径里都被频繁使用，用来快速决定：

- 当前模式空间是否允许
- 某个工具能否启用
- 当前参考结构是否偏近参考还是远参考

## 14. 设计特点总结

从源码设计上看，`Slice` 有几个很明显的特点。

### 14.1 语义状态高度集中

很多与当前图片编码语义强相关的信息都集中在 `Slice`：

- RPL
- QP / lambda
- WP
- deblock / SAO / ALF
- IRAP / CRA / DRAP 状态

这让其他模块可以通过 `cu.cs->slice` 或 `cs.slice` 直接获得上下文。

### 14.2 它既面向编码，也面向规范约束

`Slice` 里不少函数不是为了提速，而是为了保证规范一致性：

- leading picture 检查
- CRA / IDR 约束
- collocated ref 一致性
- RPL 可用性验证

因此它不只是“编码状态对象”，也是“规范约束落地点”。

### 14.3 它是 DPB 与编码器之间的桥

`Slice` 一头连着：

- `ReferencePictureList`
- `PicList`
- `Picture`

另一头连着：

- `EncSlice`
- `InterSearch`
- `CABACWriter`

这使它天然成为参考图管理和编码模块之间的中间层。

## 15. 一句话总结

`Slice` 可以概括为：

> vvenc 中承载当前切片编码语义、参考图关系、刷新规则和 slice 级工具参数的核心状态类。

如果说：

- `Picture` 表示“这一帧”
- `EncSlice` 表示“这一帧里的 slice 怎么编码”

那么 `Slice` 表示的就是：

- “这一帧里的这个 slice，在语义上是什么、能引用谁、受哪些规则约束、要带哪些参数”
