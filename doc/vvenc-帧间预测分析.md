# vvenc 帧间预测分析

本文聚焦 vvenc 的帧间预测（Inter Prediction）实现，说明其在编码器中的职责、主要算法组成，以及在源码中的具体落地方式。内容覆盖：

- 帧间预测的算法框架
- vvenc 中的调用链与模块分工
- merge / AMVP / 双向预测 / affine / MMVD / CIIP / GEO 等关键机制
- 典型执行流程图与简化伪代码

## 1. 帧间预测的目标

帧间预测的目标是利用参考帧中已重建样本，对当前块构造预测值，从而降低残差能量与编码比特数。

在 VVC / vvenc 中，帧间预测不是单一算法，而是一个候选集合，主要包括：

1. 常规运动补偿
   - 单向预测（L0 或 L1）
   - 双向预测（Bi-prediction）

2. merge 类候选
   - regular merge
   - MMVD
   - affine merge
   - CIIP
   - GEO

3. 显式运动搜索类候选
   - AMVP + motion estimation
   - IMV / AMVR
   - affine motion estimation

vvenc 的实现特点是：

- 先用较便宜的代价做候选筛选
- 再对保留候选执行完整 RD 检查
- 在不同 inter 模式之间共享中间结果，减少重复计算

## 2. 在 vvenc 中的模块分工

帧间预测的主调用链如下：

```mermaid
flowchart TD
  A[EncCu::xCompressCU] --> B[xCheckRDCostUnifiedMerge]
  A --> C[xCheckRDCostInter]
  A --> D[xCheckRDCostInterIMV]
  B --> E[xEncodeInterResidual]
  C --> F[InterSearch::predInterSearch]
  D --> F
  F --> G[xMotionEstimation / xEstimateMvPredAMVP]
  F --> H[Bi-prediction]
  F --> I[Affine Inter Search]
  E --> J[encodeResAndCalcRdInterCU]
  J --> K[最优 inter 候选]
```

职责划分可以概括为：

1. `EncCu`
   - 决定何时测试 inter 候选
   - 组织 merge / 普通 inter / IMV 的 RD 流程
   - 比较 inter 与 intra / split 候选

2. `InterSearch`
   - 完成运动预测候选构造
   - 完成运动搜索
   - 生成 inter 预测块
   - 为后续残差编码提供运动信息

3. `xEncodeInterResidual()`
   - 对选中的 inter 候选执行残差变换、量化、重建与完整 RD 检查

## 3. 帧间预测的总体算法框架

从编码器视角看，帧间预测可抽象为如下流程：

```mermaid
flowchart TD
  A[当前 CU] --> B[构造 inter 候选集合]
  B --> C[快速代价筛选]
  C --> D[运动信息确定]
  D --> E[生成预测块]
  E --> F[残差计算]
  F --> G[变换/量化/反量化/重建]
  G --> H[计算 RD cost]
  H --> I[与其他 inter 候选比较]
  I --> J[与 intra/split 候选比较]
```

这里的关键点是：  
vvenc 并不是“先定运动，再无条件编码残差”，而是将运动信息、预测质量、比特代价和残差代价统一纳入 RD 优化。

## 4. merge 类帧间预测

### 4.1 算法意义

merge 类候选的核心思想是：当前块直接复用邻域或派生候选中的运动信息，避免发送完整 MVD，从而节省比特。

vvenc 中的 merge 相关候选包括：

1. regular merge
2. MMVD
3. affine merge
4. CIIP
5. GEO

### 4.2 vvenc 实现路径

对应入口是 `EncCu::xCheckRDCostUnifiedMerge()`，其逻辑可概括为：

```text
xCheckRDCostUnifiedMerge():
  生成 regular merge 候选
  如启用 MMVD，则生成 MMVD 候选
  如启用 affine merge，则生成 affine merge 候选
  如启用 CIIP，则生成 CIIP 候选
  如启用 GEO，则生成 GEO 组合候选
  用 SATD + bit cost 做 pruning
  对保留候选执行完整 RD 检查
```

对应的简化代码形态：

```cpp
CU::getInterMergeCandidates( *cu, mergeCtx, 0 );
if( sps.MMVD )
  CU::getInterMMVDMergeCandidates( *cu, mergeCtx );

addRegularCandsToPruningList( ... );
addCiipCandsToPruningList( ... );
addMmvdCandsToPruningList( ... );
addAffineCandsToPruningList( ... );
addGpmCandsToPruningList( ... );
```

### 4.3 两阶段处理

merge 类候选在 vvenc 中通常走两阶段：

1. 候选裁剪阶段
   - 使用 SATD / 模板代价 / 近似比特代价快速筛掉差候选

2. 完整 RD 检查阶段
   - 对保留候选调用 `xEncodeInterResidual()`
   - 真正计算编码残差后的总代价

这也是 vvenc 在保持压缩效率的同时控制编码复杂度的核心手段。

### 4.4 merge 候选是怎样形成预测块的

从算法层面看，merge 不是“不做运动补偿”，而是“不显式发送完整 MVD”。  
候选一旦被选中，仍然要进入正常的运动补偿路径。

其流程可以概括为：

```mermaid
flowchart TD
  A[邻域和历史运动信息] --> B[生成 merge 候选表]
  B --> C[选择一个 mergeIdx]
  C --> D[把候选 MV refIdx interDir 写入当前 CU]
  D --> E[InterPrediction motionCompensation]
  E --> F[生成单向或双向预测块]
  F --> G[进入残差 RD]
```

也就是说，merge 节省的是“运动信息 signalling”，不是跳过预测形成本身。  
在源码里，最终的预测仍然会走 `motionCompensation()`、`xPredInterUni()` 或 `xPredInterBi()`。

## 5. 普通 inter 预测：AMVP + 运动搜索

### 5.1 算法概念

普通 inter 预测的典型流程是：

1. 为当前参考帧构造 MVP 候选
2. 选择一个 MVP 作为预测起点
3. 围绕该预测向量执行运动搜索
4. 得到最优 MV / refIdx / mvpIdx
5. 生成预测块并进入残差编码

### 5.2 vvenc 的实现入口

在 `EncCu::xCheckRDCostInter()` 中，普通 inter 候选最终会调用：

```cpp
bool stopTest = m_cInterSearch.predInterSearch(cu, partitioner, bestCostInter);
if( !stopTest )
{
  xEncodeInterResidual(tempCS, bestCS, partitioner, encTestMode, 0, 0, &equBcwCost);
}
```

也就是说：

- `InterSearch::predInterSearch()` 负责运动信息求解与预测块构造
- `xEncodeInterResidual()` 负责残差级 RD 检查

### 5.3 `predInterSearch()` 的内部结构

`InterSearch::predInterSearch()` 可以概括为：

```text
predInterSearch():
  对 L0/L1 参考列表分别遍历参考帧
  对每个参考帧:
    计算 AMVP / MVP
    执行单向运动搜索
    记录单向最佳候选
  若允许双向预测:
    组合 L0/L1 最佳候选
    执行 bi-pred refinement
  若允许 affine:
    执行 affine inter search
  返回最优 inter 运动信息
```

简化代码摘录：

```cpp
for ( int iRefList = 0; iRefList < iNumPredDir; iRefList++ )
{
  for (int iRefIdxTemp = 0; iRefIdxTemp < cs.slice->numRefIdx[ refPicList ]; iRefIdxTemp++)
  {
    xEstimateMvPredAMVP( cu, origBuf, refPicList, iRefIdxTemp, ... );
    xMotionEstimation( cu, origBuf, refPicList, cMvPred[...], iRefIdxTemp, ... );
    xCheckBestMVP( refPicList, cMvTemp[...], cMvPred[...], ... );
  }
}
```

如果把算法步骤写得更细，`predInterSearch()` 实际是在做一个分层展开的候选搜索：

```mermaid
flowchart TD
  A[当前 CU] --> B[遍历 L0 或 L1]
  B --> C[遍历 refIdx]
  C --> D[xEstimateMvPredAMVP]
  D --> E[xMotionEstimation]
  E --> F[xCheckBestMVP]
  F --> G[记录最优单向候选]
  G --> H[若允许则构造双向候选]
  H --> I[若值得则测试 affine]
  I --> J[motionCompensation 生成预测]
```

它的关键特征是：

- 先把单向候选做扎实
- 再在单向结果基础上扩展双向
- 最后只在满足门限时再展开 affine 这类高复杂度候选

这样做可以避免一开始就在完整 inter 空间上暴力穷举。

## 6. 单向预测与双向预测

### 6.1 单向预测

单向预测是 inter 搜索的基础路径：

- P slice 只需要 L0
- B slice 通常先分别搜索 L0 与 L1 的最优单向候选

vvenc 在 `predInterSearch()` 中先完成单向候选搜索，再决定是否继续执行双向预测。

### 6.2 双向预测

双向预测用于 B slice，在两个参考列表间组合候选。其好处是：

- 能更好拟合运动遮挡和复杂运动区域
- 通常能显著降低残差能量

但其代价更高，因此实现上会受以下因素约束：

1. 当前 slice 类型
2. 块大小限制
3. LDC / BCW 等约束
4. 当前候选的快速代价

从 `predInterSearch()` 可以看到，单向搜索结束后才进入 bi-pred 路径，这是一种典型的逐步扩展策略。

### 6.3 双向预测的算法细节

双向预测不是简单把两个单向预测平均。  
它的核心是：

1. 先分别找到较好的 L0 和 L1 单向候选
2. 组合成 `(refIdxL0, mvL0)` 与 `(refIdxL1, mvL1)`
3. 生成两个参考预测块
4. 按默认权重、BCW 权重或其他约束融合
5. 对组合结果再做 bit cost 与 distortion 比较

在 `xMotionEstimation()` 的双向路径里，还会先用另一侧预测块对原始块做 `removeHighFreq()`。  
它的意义是把“另一方向已经解释掉的高频成分”先去掉，让当前方向搜索更聚焦于未解释部分残差。

从工程视角看，这一步相当于：

- 单向搜索解决“大致运动”
- 双向搜索补足遮挡、前后景和时间中间帧的混合内容

### 6.4 `motionCompensation()` 如何分发单向与双向

`InterPrediction::motionCompensation()` 是 inter 预测形成的总入口。  
它不是一条固定公式，而是根据当前 CU 状态分发到不同路径：

```mermaid
flowchart TD
  A[当前 inter CU] --> B{是单向还是双向}
  B -->|单向| C[xPredInterUni]
  B -->|双向| D[检查 BDOF 和 DMVR 条件]
  D --> E{是否 identical motion}
  E -->|是| C
  E -->|否| F{是否 DMVR}
  F -->|是| G[xProcessDMVR]
  F -->|否| H[xPredInterBi]
  H --> I[双向融合输出]
  C --> J[预测块]
  G --> J
  I --> J
```

这说明编码器选中的并不是单一“MV”，而是一整套预测形成规则。

## 7. AMVP、MVP 与运动搜索

### 7.1 MVP / AMVP

MVP 是运动向量预测；AMVP 是基于邻居构造的候选集合。其目标是：

- 降低运动信息编码比特
- 为运动搜索提供更可靠的初值

vvenc 中的关键步骤包括：

1. `xEstimateMvPredAMVP()`
   - 构造/评估 AMVP 候选

2. `xMotionEstimation()`
   - 以所选 MVP 为中心进行搜索

3. `xCheckBestMVP()`
   - 在 bit cost 维度重新评估最优 MVP

### 7.2 运动搜索

运动搜索的本质是寻找一组 MV/refIdx，使：

`预测失真 + lambda * 运动信息比特`

最小。

vvenc 中的运动搜索不是孤立过程，而是与：

- 参考帧索引选择
- MVP 选择
- IMV / AMVR
- bi-pred
- affine

共同组成 inter 候选空间。

### 7.3 `xEstimateMvPredAMVP()` 和 `xCheckBestMVP()` 的分工

这两个步骤虽然都和 MVP 有关，但职责不同：

#### `xEstimateMvPredAMVP()`

它解决的是“先拿哪个预测向量作为搜索起点更好”。  
常见依据包括：

- 邻居块继承来的运动向量
- 时域/空间派生候选
- 模板代价或初始预测误差

#### `xCheckBestMVP()`

它解决的是“在已经找到某个 MV 后，用哪个 MVP 编码 MVD 最便宜”。  
因为同一个最终 MV，相对不同 MVP 得到的 MVD 长度不同，CABAC 代价也会不同。

所以 inter 搜索里实际有两层决策：

1. 哪个 MVP 更适合拿来搜索
2. 哪个 MVP 更适合拿来编码

这也是为什么源码里运动估计完成后，还要再跑一次 `xCheckBestMVP()`。

### 7.4 `xMotionEstimation()` 的详细算法

`xMotionEstimation()` 是普通 translational inter 的核心。  
它不是“直接在一个固定窗口里暴搜”，而是由多个阶段组成：

```text
xMotionEstimation():
  设定搜索范围和代价函数
  用 MVP 或缓存 MV 作为初始点
  做整数像素搜索
  若允许亚像素，则做 half / quarter refinement
  若是整数精度模式，则做 integer refine
  结合 MV bit cost 更新总代价
```

从实现细节看，它有几个关键设计：

#### 搜索起点不只一个

除了 `rcMvPred`，函数还会尝试：

- 当前模式相关缓存的 uni motion
- 关联块保存的 MV
- 双向路径中的另一侧约束结果

这样可以避免把搜索质量完全押在单个 MVP 上。

#### 整数像素与亚像素分层

整数搜索先解决大范围位移，随后：

- `xPatternSearchFracDIF()` 负责 half-pel / quarter-pel 精细化
- `xPatternSearchIntRefine()` 用于 IMV 之类整数精度模式下的细化

这符合视频编码里最常见的 ME 结构：  
先粗搜找到 basin，再用插值滤波做精修。

#### 代价函数不是纯失真

`xMotionEstimation()` 比较的是：

```text
SAD 或 SATD 类失真 + MV bit cost
```

而且在 bi-pred 路径里还会乘上与 BCW 相关的权重。  
这意味着最优 MV 不一定是预测误差最小的那个，而是 RDO 意义下总成本最低的那个。

### 7.5 TZ Search 与快速搜索的意义

从 `xTZSearch()`、`xPatternSearchFast()`、`xPatternSearch()` 这些函数名就能看出，vvenc 并不只用一种搜索法。

可以把它们理解成三类策略：

1. 全搜索或近似全搜索
   - 质量高，复杂度也高

2. TZ Search
   - 以中心点为起点，在十字、方形、栅格等图案上逐步扩展
   - 适合大多数工程场景

3. 快速模式
   - 借助缓存 MV、邻块 MV、块级历史信息直接缩小搜索范围

这也是 vvenc 能同时兼顾压缩率和编码速度的原因之一。

## 8. IMV / AMVR

### 8.1 算法作用

IMV / AMVR 的目标是：

- 在整数、半像素等不同精度层级上控制运动参数表示
- 用更粗的 MV 精度换取更低的比特或更低的搜索复杂度

### 8.2 vvenc 中的实现方式

对应入口是 `EncCu::xCheckRDCostInterIMV()`。其简化逻辑是：

```text
xCheckRDCostInterIMV():
  对不同 IMV 精度模式循环
  在每个精度上执行 inter 搜索
  根据快速门限决定是否继续细化
  对保留候选调用 xEncodeInterResidual()
```

这类路径通常只在满足配置和快速判据时展开，因此它是一种“选择性扩展”的 inter 模式。

### 8.3 IMV 为什么不只是“降精度”

IMV / AMVR 的收益不只来自语法比特减少，还来自搜索空间变化。

当 MV 精度被限制为整数或 4-pel 时：

- 候选点更稀疏
- 搜索和 refinement 更便宜
- MVD 编码长度往往更短
- 某些平滑块中损失的预测精度有限

所以 IMV 实际上是在做一笔工程化交易：

```text
少量预测精度损失
换取更低复杂度和更低运动信息码率
```

## 9. affine 帧间预测

### 9.1 算法意义

普通平移模型只能表达平移运动；affine 模型可以表达：

- 旋转
- 缩放
- 剪切

在非刚性或视角变化明显的区域更有效。

### 9.2 vvenc 实现要点

在 `InterSearch::predInterSearch()` 中，affine 相关逻辑主要表现为：

1. 判断是否值得检查 affine
2. 调用 `xPredAffineInterSearch()`
3. 比较 4 参数 / 6 参数 affine 成本
4. 与普通 translational inter 候选比较

简化伪代码：

```text
if( checkAffine && 块尺寸满足条件 )
{
  执行 4 参数 affine 搜索
  如启用 6 参数 affine，再继续细化
  将 affine 候选与普通 inter 候选比较
}
```

这说明 affine 在 vvenc 中并不是默认强制执行，而是一个受尺寸、时层、快速门限控制的高复杂度增强候选。

### 9.3 affine 的预测模型究竟是什么

普通平移模型对整块只使用一个 MV；affine 则让块内不同位置的 MV 随坐标变化。  
因此它可以描述：

- 旋转造成的局部方向变化
- 缩放造成的位移梯度
- 剪切造成的非均匀位移

在 vvenc 里，4 参数和 6 参数的差别，可以粗略理解为：

- 4 参数：足以覆盖平移加部分旋转缩放
- 6 参数：表达能力更强，但搜索和 signalling 代价也更高

### 9.4 affine 搜索不是三个位移独立穷举

从 `xPredAffineInterSearch()`、`xEstimateAffineAMVP()`、`xCheckBestAffineMVP()` 和后面的 equal-coefficient 求解逻辑看，affine 搜索更接近一个迭代优化问题。

可以抽象成：

```text
生成 affine AMVP 候选
选择角点 MV 初值
根据预测误差和导数建立线性方程
求解参数增量
更新角点 MV
重复直到代价不再下降
```

这和 translational ME 的“点搜索”不同，affine 更像是在参数空间里做局部最优化。

### 9.5 affine 运动补偿如何形成块内 MV

affine 最终仍然要落回到像素级运动补偿。  
做法不是为每个像素单独存 MV，而是：

1. 先确定角点控制 MV
2. 对子块或像素位置按仿射关系插值得到局部 MV
3. 再对参考帧做插值采样
4. 形成整个预测块

这也是 `InterPrediction` 里 affine 路径比普通 `xPredInterUni()` 更重的原因。

## 10. CIIP、GEO 与 MMVD

### 10.1 CIIP

CIIP（Combined Intra Inter Prediction）本质上是把 inter 预测和 intra 预测混合，用于改善仅 inter 预测不足的情况。

在 vvenc 中，CIIP 作为 merge 类候选插入 pruning 列表，随后参与统一 RD 检查。

从预测算法上，CIIP 不是“先 inter 失败再补 intra”，而是显式构造：

```text
最终预测 = inter 预测 与 intra 预测 的组合
```

它适合的通常是：

- 背景大体可由 inter 解释
- 但局部纹理或边界仅靠 inter 仍有系统误差

因此它本质上是一种混合预测器。

### 10.2 GEO

GEO（Geometric Partitioning Mode）通过几何分区把块拆成两个预测区域，每个区域可使用不同 merge 候选，适合边界清晰的复杂运动区域。

vvenc 的 GEO 处理流程是：

1. 构造几何组合候选
2. 用 weighted SAD / SATD 做快速排序
3. 对少量优选 GEO 组合做完整 RD

从算法上看，GEO 的关键不是普通 split，而是“两个 merge 候选加一个几何掩码”。  
编码器并不发送两块独立子 CU，而是发送：

- 一个几何分割方向
- 两个 merge 索引
- 对应的组合方式

预测块生成时，两套 inter 预测通过几何模板在块内拼接。

### 10.3 MMVD

MMVD 是在 merge 基础上对运动矢量做离散 refinement。  
它本质上是“低 signalling cost 的细化 merge 方案”。

vvenc 中，MMVD 也是先插入 pruning list，再进入完整 RD 检查。

它的算法意义可以概括为：

- 基底来自 merge 候选
- 再按预定义方向和步长做有限组 MV 偏移
- 只在小离散集合内细化，而不是重新完整做 ME

所以 MMVD 本质上是“低开销的 merge 细化器”。

### 10.4 BCW、DMVR 与 BDOF

这几个工具都发生在双向预测附近，但作用完全不同。

#### BCW

BCW（Bi-prediction Combination Weight）解决的是两侧预测块如何加权融合。  
它不改变参考位置，只改变融合权重。

#### DMVR

DMVR（Decoder-side Motion Vector Refinement）解决的是 merge 双向候选的 MV 还不够准。  
它以 merge MV 为起点，在一个小局部窗口内做双向 refinement，再形成最终预测。

`motionCompensation()` 中当 `cu.mvRefine` 且满足 `checkDMVRCondition()` 时，会转到 `xProcessDMVR()`，而不是直接 `xPredInterBi()`。

#### BDOF

BDOF（Bi-directional Optical Flow）不是重新选 MV，而是在双向预测块已经得到之后，利用局部梯度做像素级补偿。  
它更像是对双向融合结果做细粒度修正。

因此三者关系可以理解为：

```text
BCW 负责怎么加权
DMVR 负责怎么修正双向 MV
BDOF 负责怎么修正像素级双向对齐误差
```

## 11. inter 残差编码与最终 RD 判定

无论候选来自：

- merge
- 普通 inter
- IMV
- affine

最终都会走向 `xEncodeInterResidual()` 完成真正的 RD 检查。

其职责可概括为：

```text
xEncodeInterResidual():
  根据当前运动信息生成预测块
  形成残差
  进行变换/量化/反量化/重建
  计算失真
  估算语法比特
  计算完整 RD cost
  更新 bestCS
```

这一步非常关键，因为它决定：

- 哪个 inter 候选真正成为当前 CU 的最优模式
- inter 候选能否击败 intra 或 split 候选

### 11.1 为什么 `predInterSearch()` 之后还不算结束

`predInterSearch()` 找到的是一个“运动上看起来最有希望”的候选，  
但最终输赢还取决于残差是否好编码。

这是因为：

- MV 更复杂，bit 也更多
- 预测误差更小，不一定意味着变换后更稀疏
- 某些 merge 候选虽然预测略差，但几乎不需要发送运动信息

所以真正被比较的是：

```text
运动信息比特 + 残差比特 + 重建失真
```

这也是 inter 路径必须经过 `xEncodeInterResidual()` / `encodeResAndCalcRdInterCU()` 的根本原因。

## 12. vvenc 帧间预测的工程化特点

### 12.1 候选空间大，但有强 pruning

vvenc 的 inter 候选非常丰富，但并不暴力穷举，而是通过：

- SATD
- 模板代价
- 快速门限
- 时层与块大小约束

控制展开规模。

### 12.2 共享中间结果

实现中存在大量缓存/复用机制，例如：

- uni motion reuse
- affine motion 缓存
- merge pruning list

这能显著减少重复搜索。

### 12.3 将运动搜索与 RD 检查分层

`predInterSearch()` 解决“运动怎么取”，  
`xEncodeInterResidual()` 解决“总代价是否最优”。

这种分层使实现更清晰，也更容易插入快速路径。

### 12.4 inter 路径中的缓存为什么重要

从实现上能看到多类缓存：

- uni motion reuse
- affine motion reuse
- 相关 CU 历史 MV
- merge pruning list

这些缓存的价值在于：

- 相邻块运动往往高度相关
- 同一块在不同 inter 模式下会重复访问相近 MV
- affine 和 bi-pred 的搜索代价很高，复用初值收益明显

因此 vvenc 的 inter 搜索并不是“每个候选从零开始”，而是强依赖历史与邻域信息。

## 13. 建议的阅读顺序

如果继续深入帧间预测实现，建议按如下顺序读：

1. `EncCu::xCheckRDCostUnifiedMerge()`
2. `EncCu::xCheckRDCostInter()`
3. `EncCu::xCheckRDCostInterIMV()`
4. `InterSearch::predInterSearch()`
5. `InterSearch::xEstimateMvPredAMVP()`
6. `InterSearch::xMotionEstimation()`
7. `InterSearch::xTZSearch()`
8. `InterSearch::xCheckBestMVP()`
9. `InterPrediction::motionCompensation()`
10. `InterPrediction::xPredInterUni()`
11. `InterPrediction::xPredInterBi()`
12. `InterSearch::xPredAffineInterSearch()`
13. `EncCu::xEncodeInterResidual()`

按这个顺序，可以先建立 inter 决策框架，再深入运动估计和高级候选。
