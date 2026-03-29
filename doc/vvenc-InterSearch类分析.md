# vvenc `InterSearch` 类分析

## 1. 类定位

`InterSearch` 是 vvenc 中负责显式帧间搜索的核心类。

它的职责不是简单“做一次运动估计”，而是把下面几件事串成一个完整决策闭环：

- 为当前 `CU` 构造单向 / 双向 inter 候选
- 基于 `AMVP` 做运动向量预测与运动搜索
- 在需要时继续做 affine inter search
- 在 SCC / IBC 场景下完成块复制搜索
- 为后续残差编码阶段写回最优运动信息

从模块职责上说：

- `InterPrediction` 负责“怎么按已有运动信息生成预测块”
- `InterSearch` 负责“应该选什么运动信息”

因此 `InterSearch` 更接近“帧间模式搜索与 RDO 前端执行器”。

## 2. 在编码流程中的位置

`InterSearch` 位于 `EncCu` 之下，主要调用链可以概括为：

```text
EncCu::xCheckRDCostInter()
  -> InterSearch::predInterSearch()
  -> EncCu::xEncodeInterResidual(...)
  -> InterSearch::encodeResAndCalcRdInterCU()
```

对应关系是：

- `EncModeCtrl` 决定当前 CU 是否值得测试 inter
- `EncCu` 负责组织 `CodingStructure`、模式竞争和 best mode 更新
- `InterSearch::predInterSearch()` 负责确定运动信息
- `InterSearch::encodeResAndCalcRdInterCU()` 负责残差编码与最终 RD 代价计算

也就是说，`InterSearch` 横跨了“运动搜索”和“inter 残差 RD”两段流程。

## 3. 理论背景

### 3.1 帧间预测的目标

帧间预测要解决的问题是：

- 在参考帧中找到最合适的匹配区域
- 用运动向量和参考索引生成预测块
- 尽量减小残差能量与运动信息比特

其优化目标仍然是：

```text
J = D + lambda * R
```

其中：

- `D` 是预测误差和残差重建后的失真
- `R` 包含参考索引、MVP 索引、MVD、残差等比特代价

### 3.2 `InterSearch` 处理的主要工具

`InterSearch` 覆盖的并不只是普通整数运动搜索，还包括：

- 单向预测 `L0/L1`
- 双向预测 `Bi-pred`
- `AMVP`
- `TM`/`TZ search` 风格整数搜索与分数像素精化
- `Affine` 4 参数 / 6 参数搜索
- `BCW` 相关权重选择协同
- `SBT` 残差模式预估
- `IBC` 块复制搜索

所以这个类既是运动搜索器，也是若干 inter 工具的调度中心。

## 4. 类结构与关键成员

类定义如下：

```cpp
class InterSearch : public InterPrediction, AffineGradientSearch
```

这说明它有两层基础能力：

- 继承 `InterPrediction`
  - 复用运动补偿、双向预测、插值滤波等底层预测能力
- 继承 `AffineGradientSearch`
  - 复用 affine 梯度优化相关能力

关键成员大致可分成几组。

### 4.1 外部依赖

```cpp
const VVEncCfg* m_pcEncCfg;
TrQuant*        m_pcTrQuant;
RdCost*         m_pcRdCost;
EncModeCtrl*    m_modeCtrl;
CABACWriter*    m_CABACEstimator;
CtxCache*       m_CtxCache;
```

分别承担：

- 编码配置读取
- 变换量化
- RD 代价估计
- 模式控制
- CABAC 比特估计
- 上下文缓存

### 4.2 搜索参数与代价缓存

```cpp
int                 m_iSearchRange;
int                 m_bipredSearchRange;
vvencMESearchMethod m_motionEstimationSearchMethod;
int                 m_aaiAdaptSR[...][...];
uint32_t            m_auiMVPIdxCost[...][...];
```

作用分别是：

- 控制普通 ME 搜索范围
- 控制双向预测搜索范围
- 选择搜索方法
- 根据参考列表 / 参考索引自适应调整搜索范围
- 缓存 MVP 索引 bit 成本

### 4.3 临时缓冲与中间结果

```cpp
PelStorage        m_tmpPredStorage[NUM_REF_PIC_LIST_01];
PelStorage        m_tmpStorageLCU;
PelStorage        m_tmpAffiStorage;
Pel*              m_pTempPel;
Pel*              m_tmpAffiError;
Pel*              m_tmpAffiDeri[2];
```

这些缓冲用于：

- 普通 inter 候选预测块暂存
- CTU 级临时像素缓存
- affine 搜索中的预测、误差和梯度缓存

这部分反映出 `InterSearch` 是高频热点类，因此大量依赖复用型缓冲来减少重复分配。

### 4.4 运动复用与缓存

```cpp
ReuseUniMv*         m_ReuseUniMv;
BlkUniMvInfoBuffer* m_BlkUniMvInfoBuffer;
AffineProfList*     m_AffineProfList;
EncAffineMotion     m_affineMotion;
```

这是 vvenc 降复杂度的重要设计：

- `ReuseUniMv`
  - 按区域缓存已算过的单向 MV
- `BlkUniMvInfoBuffer`
  - 记录块级 uni-MV 候选
- `AffineProfList`
  - 缓存 affine MV 结果
- `m_affineMotion`
  - 保存当前 affine 搜索中的 4 参数 / 6 参数结果

本质上，这些成员都在做“结果复用”，避免不同候选和相邻块重复搜索。

### 4.5 IBC 相关成员

```cpp
Mv                m_acBVs[2 * IBC_NUM_CANDIDATES];
unsigned int      m_numBVs;
IbcBvCand*        m_defaultCachedBvs;
std::unordered_map< Position, std::unordered_map< Size, BlkRecord> > m_ctuRecord;
```

这些成员用于屏幕内容编码时的块复制搜索：

- 保存 IBC 候选块向量
- 保存默认缓存候选
- 记录 CTU 内搜索记录，减少重复访问

## 5. 生命周期与初始化

### 5.1 `init()`

`init()` 做的事情主要有：

- 调用 `InterPrediction::init()`
- 保存外部依赖指针
- 读取搜索范围、双向搜索范围、ME 搜索方法
- 预计算 `m_auiMVPIdxCost`
- 创建普通 inter 与 affine 用的临时缓冲
- 创建色度残差缓存

可以把它理解为：为一个 CTU 内高频调用的热点搜索器预热运行环境。

### 5.2 `setCtuEncRsrc()`

每个 CTU 编码时，`EncCu` 会把当前上下文挂进来：

- `CABACWriter`
- `CtxCache`
- 单向 MV 复用池
- 块级 uni-MV 缓冲
- affine 结果缓存
- IBC 候选缓存

因此 `InterSearch` 虽然是类成员，但其部分运行资源是按 CTU 动态切换的。

## 6. `predInterSearch()` 主流程

### 6.1 入口职责

`predInterSearch()` 是普通 inter 路径的核心入口，负责：

1. 遍历参考列表与参考帧
2. 为每个参考帧建立 MVP / AMVP
3. 执行单向运动搜索
4. 决定是否进入双向预测
5. 决定是否继续 affine inter search
6. 把当前最优运动信息写回 `CU`

### 6.2 主流程概括

它的主体逻辑可以抽象成：

```text
predInterSearch():
  初始化局部候选、比特与代价缓存
  对 L0/L1 的每个 refIdx:
    xEstimateMvPredAMVP()
    xMotionEstimation()
    xCheckBestMVP()
    更新该 list 的最优单向候选

  必要时缓存 uni-MV 结果，供后续块复用

  若允许双向预测:
    组合单向最优结果
    做 bi-pred refinement / symmetric search

  若允许 affine:
    调用 xPredAffineInterSearch()

  输出当前最优 inter 运动信息
```

这个函数的特点是“逐层扩展候选空间”：

- 先做便宜的单向搜索
- 再做更贵的双向搜索
- 最后在合适条件下再试 affine

这能避免一开始就把最重的路径全开。

### 6.3 单向搜索阶段

单向阶段是整个函数的基础。

对每个 `refPicList` / `refIdx`，核心步骤是：

1. `xEstimateMvPredAMVP()`
   - 为当前参考帧构造 AMVP 候选
   - 给出初始 MVP 和相关代价

2. `xMotionEstimation()`
   - 以 MVP 为中心做整数 / 分数像素搜索

3. `xCheckBestMVP()`
   - 结合运动比特重新检查最优 MVP 索引

4. 更新当前 list 最优候选
   - 记录最佳 `MV`、`refIdx`、`bits`、`cost`

这一阶段得到的是：

- `L0` 最优单向候选
- `L1` 最优单向候选
- 为双向搜索保留的中间信息

### 6.4 结果复用

当 `cu.imv == IMV_OFF` 且当前场景允许时，`predInterSearch()` 会把单向搜索结果写入：

- `m_BlkUniMvInfoBuffer`
- `m_ReuseUniMv`

这是一个很关键的复杂度优化点：

- 当前块算出的 uni-MV 可以给后续相同尺寸 / 邻近位置块复用
- 减少重复 motion estimation
- 对编码速度影响明显

### 6.5 提前终止

`predInterSearch()` 还会结合 `bestCostInter` 做一次快速早停。

如果已有 merge 候选明显更优，而当前显式 inter 候选代价差距过大，就直接返回 `true` 让上层停止继续测试。这说明：

- `InterSearch` 不是孤立搜索器
- 它始终处在“与 merge / 其他模式竞争”的大框架里

## 7. 运动估计相关子模块

### 7.1 `xEstimateMvPredAMVP()`

这个函数负责：

- 生成当前参考的 AMVP 候选
- 评估候选模板代价
- 选出 MVP 起点

它的意义是把“邻域已有运动信息”转化成当前块的搜索起点，既降低比特，又减少搜索范围压力。

### 7.2 `xMotionEstimation()`

这是普通块 ME 的核心执行器。

其内部会完成：

- 搜索范围设置
- 整数像素搜索
- 分数像素精化
- MV 比特与失真联合代价计算

它本身不负责最终模式决策，而是回答：

“针对这个参考索引，当前最优 MV 是什么？”

### 7.3 `xTZSearch()` 及相关辅助函数

`xTZSearchHelp()`、`xTZ2PointSearch()`、`xTZ8PointSquareSearch()` 等函数组成了整数像素搜索的实现主体。

可以把它理解为：

- 围绕预测向量做多点形状搜索
- 逐步逼近最优整数 MV
- 再交给分数像素精化阶段继续优化

这部分属于典型的视频编码器热点路径。

### 7.4 `xPatternSearchFracDIF()`

这个函数负责分数像素精化：

- 基于插值滤波得到 half / quarter pel 候选
- 比较不同亚像素位置代价
- 输出更精细的 MV

因此普通 inter 搜索的完整链路是：

```text
AMVP 预测
-> 整数搜索
-> 分数像素搜索
-> MVP 重新选择
```

## 8. 双向预测与对称搜索

在 B slice 中，`InterSearch` 会在单向搜索后继续尝试双向预测。

相关函数包括：

- `xGetSymCost()`
- `xSymRefineMvSearch()`
- `xSymMotionEstimation()`
- `xSymMvdCheckBestMvp()`

这一层的目标是：

- 把 L0 和 L1 的单向结果组合起来
- 在双向场景下进一步细化两侧 MV
- 兼顾 `BCW`、`mvdL1Zero`、LDC 等约束

从实现风格上看，vvenc 并不是“盲目遍历所有 bi-pred 组合”，而是：

- 先用单向最优结果做起点
- 再对少量高价值组合做细化

这样复杂度才可控。

## 9. Affine 搜索

### 9.1 入口

`xPredAffineInterSearch()` 是 affine inter 的主入口。

它在逻辑上与普通 inter 很像，但搜索对象从“单个 MV”变成了“控制点 MV 集合”。

### 9.2 主要流程

其大致流程可以概括为：

```text
xPredAffineInterSearch():
  对 L0/L1 每个 refIdx:
    xEstimateAffineAMVP()
    评估 hevcMv / 已缓存 affine MV / AMVP 起点
    xAffineMotionEstimation()
    xCheckBestAffineMVP()
    更新 affine 最优单向候选

  若允许双向 affine:
    继续组合 bi-pred affine 候选

  保存 affine 最优结果
```

### 9.3 核心特点

与普通 inter 相比，affine 搜索的特点是：

- 运动模型更复杂
- 候选起点更多
- 非常依赖缓存和复用

因此代码里会显式使用：

- `hevcMv` 结果作为起始点
- `m_affineMotion` 中已保存的历史结果
- `AffineProfList` 中的块级缓存

这说明 vvenc 把 affine 当成高收益但高代价工具，必须强依赖启发式和复用。

## 10. IBC 路径

### 10.1 `predIBCSearch()`

`predIBCSearch()` 是屏幕内容编码的块复制搜索入口。

它的工作流程大致是：

1. 构造 IBC MVP 候选
2. 调用 `xIBCEstimation()` 在当前图像已编码区域内搜索块向量
3. 选择最佳 BVP 索引和 IMV 精度
4. 把结果写回 `CU`

与普通 inter 的区别在于：

- 参考不是另一帧，而是当前帧已重建区域
- 搜索对象是块向量 `BV`
- 需要严格满足可访问区域约束

### 10.2 IBC 相关辅助函数

IBC 路径还依赖：

- `xSetIntraSearchRangeIBC()`
- `xIntraPatternSearchIBC()`
- `xIBCSearchMVChromaRefine()`
- `searchBvIBC()`

这些函数分别处理：

- 搜索范围构造
- IBC 模式搜索
- 色度精化
- BV 合法性检查

所以 IBC 虽然入口也放在 `InterSearch`，但实际上是一条与普通参考帧搜索明显不同的分支。

## 11. 残差编码与最终 RD

### 11.1 `encodeResAndCalcRdInterCU()`

这个函数负责把“已确定运动信息的 inter 候选”推进到完整 RD 计算。

它分成两条路径：

1. `skipResidual == true`
   - 直接走 skip / no-residual 路径
   - 复制预测到重建
   - 估计 skip flag、merge data 比特
   - 计算总代价

2. `skipResidual == false`
   - 构造残差
   - 进入变换、量化、反量化、重建流程
   - 递归评估 TU / SBT / joint chroma 等
   - 计算完整 inter RD 代价

因此它回答的是：

“这个 inter 运动假设，在完整编码后到底值不值得选？”

### 11.2 `xEstimateInterResidualQT()`

这是 inter 残差树搜索的核心函数。

它会联合考虑：

- luma / chroma 残差
- QT 划分
- `SBT`
- `rootCbf`
- CABAC 比特估计

这说明 `InterSearch` 并不止步于运动搜索，而是把 inter 模式的后半段 RDO 也包进来了。

### 11.3 `SBT` 相关

`InterSearch` 中还有一组和 `SBT` 强相关的接口：

- `getBestSbt()`
- `xCalcMinDistSbt()`
- `skipSbtByRDCost()`

它们的作用是：

- 估计不同 SBT 模式的最小失真
- 决定测试顺序
- 在代价明显不优时提早跳过某些 SBT 模式

这进一步体现了类的“搜索器”本质：

- 搜的不只是 MV
- 也在搜 inter 残差表达方式

## 12. 设计特点总结

从实现上看，`InterSearch` 有几个很鲜明的特点。

### 12.1 分层搜索

它不是一次性展开所有候选，而是按代价逐层推进：

- 单向
- 双向
- affine
- 残差 RD

这样能把高复杂度工具限制在少量高价值候选上。

### 12.2 强缓存复用

类中有大量缓存结构：

- uni-MV 复用
- affine 结果复用
- CTU 内 IBC 记录
- 临时预测块缓冲

这说明 vvenc 在 inter 搜索上非常重视“避免重复工作”。

### 12.3 运动搜索与残差 RDO 一体化

很多实现会把运动搜索和残差编码割裂成两个模块，但 `InterSearch` 明显更一体化：

- 前半段决定运动信息
- 后半段直接评估 inter 残差编码代价

这种组织方式更利于做早停、复用和工具联动。

## 13. 一句话总结

`InterSearch` 可以概括为：

> vvenc 中负责显式帧间模式搜索、运动估计、affine/IBC 扩展以及 inter 残差 RD 收口的核心执行类。

如果说：

- `EncCu` 负责“组织模式竞争”
- `InterPrediction` 负责“按给定 MV 生成预测”

那么 `InterSearch` 负责的就是：

- “这个块的 inter 运动信息该怎么找”
- “找完之后，这个 inter 候选到底值不值得保留”
