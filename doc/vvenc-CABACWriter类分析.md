# vvenc `CABACWriter` 类分析

## 1. 类定位

`CABACWriter` 是 vvenc 中负责把编码结果写成 CABAC 语法比特流的核心类。

它的职责不是做模式决策，而是：

- 按 VVC 语法顺序遍历已经确定好的编码结果
- 根据当前上下文模型选择合适的概率状态
- 调用底层 `BinEncoder` 输出上下文编码 bin、旁路 bin 和终止 bin

从职责上看，它是：

- 编码器语法写出层
- CABAC 上下文驱动层
- `CodingStructure` 到实际 bitstream 的桥接器

一句话说：

`CABACWriter` 负责回答“这些已经选好的编码结果，应该怎样按 CABAC 语法真正写出去”。

## 2. 在编码链路中的位置

`CABACWriter` 位于模式决策之后、比特流输出之前。

其位置可以概括为：

```text
EncCu / InterSearch / IntraSearch
  -> 产出最优 CU / TU / MV / coeff / filter 参数
  -> EncSlice::encodeSliceData()
     -> CABACWriter::coding_tree_unit()
        -> coding_tree()
        -> coding_unit()
        -> prediction_unit()
        -> transform_unit()
        -> residual_coding()
        -> BinEncoder
        -> OutputBitstream
```

也就是说：

- 上游模块负责“选什么”
- `CABACWriter` 负责“怎么写”

## 3. 与 `BinEncoder` 的关系

类定义如下：

```cpp
class CABACWriter : public DeriveCtx
```

构造函数是：

```cpp
CABACWriter(BinEncIf& binEncoder)
```

这说明它本身不直接做算术编码，而是依赖底层 `BinEncIf` / `BinEncoder`。

分工大致是：

- `CABACWriter`
  - 决定写哪些 syntax element
  - 决定这些 element 对应的 context id
  - 决定走普通上下文编码还是 bypass 编码

- `BinEncoder`
  - 维护 CABAC 内部状态机
  - 完成二进制算术编码
  - 写入 `OutputBitstream`

所以 `CABACWriter` 更像“CABAC 语法编排器”，而不是底层算术编码器本身。

## 4. 关键成员

### 4.1 底层编码接口

```cpp
BinEncIf&        m_BinEncoder;
OutputBitstream* m_Bitstream;
Ctx              m_TestCtx;
```

它们分别承担：

- `m_BinEncoder`
  - 真正执行 bin 编码
- `m_Bitstream`
  - 最终输出目标
- `m_TestCtx`
  - 用于 CABAC init table 评估

### 4.2 递归遍历辅助状态

```cpp
Partitioner m_partitioner[2];
CtxTpl      m_tplBuf[MAX_TB_SIZEY * MAX_TB_SIZEY];
const ScanElement* m_scanOrder;
```

这些成员用于：

- CTU / CU / TU 递归遍历
- 系数扫描与残差编码上下文
- Luma/Chroma 分树时的独立 partitioner

这说明 `CABACWriter` 不是简单线性输出器，而是要根据树结构递归行走整棵 coding tree。

## 5. 生命周期与基础接口

### 5.1 `initBitstream()`

这个函数把当前 writer 绑定到 `OutputBitstream`，并初始化底层 `BinEncoder`。

### 5.2 `initCtxModels()`

这个函数根据当前 `Slice` 的：

- `sliceQp`
- `sliceType`
- `encCABACTableIdx`

初始化 CABAC 上下文模型。

要点是：

- 默认按当前 `sliceType` 初始化
- 若 PPS 允许 `cabac_init_present_flag`，则可能改用 `encCABACTableIdx`

因此它负责回答：

“这一整个 slice，从什么上下文模型起步？”

### 5.3 `getCtxInitId()`

这个函数会估算使用 `P-slice` 还是 `B-slice` 初始化表更省比特。

其内部思路是：

- 用 `m_TestCtx` 分别试初始化成 P/B 上下文
- 结合当前 bin 统计估算额外代价
- 选更优的初始化类型

这说明 vvenc 的 CABAC init 不是固定死的，而是会基于当前编码统计做自适应选择。

### 5.4 `start()` / `end_of_slice()`

对应一次 slice 的 CABAC 编码开始和结束：

- `start()` 开启编码
- `end_of_slice()` 写终止 bin 并 `finish()`

## 6. 主入口：`coding_tree_unit()`

`coding_tree_unit()` 是 `CABACWriter` 的 CTU 级总入口。

它的流程可以概括为：

```text
coding_tree_unit():
  初始化 CUCtx 和 partitioner
  写 SAO
  写 ALF / CCALF
  进入 coding_tree()
  更新 luma / chroma QP 状态
```

这个函数的重要性在于：

- 它定义了 CTU 级语法元素的整体写出顺序
- 它把滤波类语法和 coding tree 语法串起来

### 6.1 SAO / ALF 先行

在进入 `coding_tree()` 前，会先写：

- `sao()`
- `codeAlfCtuEnabledFlag()`
- `codeAlfCtuFilterIndex()`
- `codeCcAlfFilterControlIdc()`

这说明：

- CTU 级滤波语法是 `coding tree` 外围语法的一部分
- `CABACWriter` 统一负责编码，不拆给各后处理模块自己输出

## 7. `coding_tree()`：递归树遍历核心

`coding_tree()` 是整棵 CU 树递归写出的入口。

它主要做三件事：

1. 处理 quantization group 相关状态
2. 决定当前节点是否 split
3. 若不 split，则写当前 `CodingUnit`

可以概括成：

```text
coding_tree():
  取当前 area 对应 cu
  初始化 qg / chroma qp adj 状态
  split_cu_mode()
  如果 split:
    mode_constraint()
    splitCurrArea()
    递归写子块
  否则:
    coding_unit()
```

因此 `coding_tree()` 解决的是：

- “树怎么展开”
- “什么时候进入叶子 CU 语法”

### 7.1 `split_cu_mode()`

这个函数按规范写 split 相关语法：

- `split_cu_flag`
- `qt_split_flag`
- `mtt_hv_flag`
- `split12_flag`

它会先看当前 `Partitioner` 的可分裂状态，再只写合法分支需要的 bin。

### 7.2 `mode_constraint()`

这个函数用于写 mode constraint 相关语法，表达当前 split 后子块是否受 `MODE_TYPE` 限制。

这部分体现出 `CABACWriter` 不是只写叶子节点，它也负责树结构约束语法。

## 8. `coding_unit()`：叶子 CU 语法总入口

当当前节点不再 split 时，`coding_tree()` 会进入 `coding_unit()`。

它的逻辑很清晰：

```text
coding_unit():
  写 skip flag
  若 skip:
    写 prediction_unit()
    end_of_ctu()
    返回

  写 pred_mode()
  写 cu_pred_data()
  写 cu_residual()
  end_of_ctu()
```

这说明 `coding_unit()` 是 CU 级语法的组织器，而不是每个 syntax element 的具体实现者。

它把一个 CU 分成三层：

- 模式层
- 预测信息层
- 残差层

## 9. 预测相关语法

### 9.1 `cu_skip_flag()` 和 `pred_mode()`

这两个函数先决定：

- 当前 CU 是否 skip
- 当前是 intra / inter / IBC 等哪种预测模式

这里会结合：

- `IBC` 是否启用
- 当前块大小是否合法
- `ConsIntra/ConsInter` 约束

所以它不是机械写 flag，而是严格依赖当前 `CU` 和 `SPS/Slice` 条件。

### 9.2 `cu_pred_data()`

这是预测信息的大入口。根据 `CU` 类型，它会继续调用：

- intra 相关函数
  - `intra_luma_pred_modes()`
  - `intra_chroma_pred_mode()`
  - `mip_flag()` / `mip_pred_mode()`
  - `isp_mode()`

- inter 相关函数
  - `prediction_unit()`
  - `merge_flag()`
  - `merge_data()`
  - `inter_pred_idc()`
  - `ref_idx()`
  - `mvp_flag()`
  - `mvd_coding()`

这部分是 CABAC 里最复杂的分支之一，因为预测模式空间最大。

## 10. `prediction_unit()`：inter 语法核心

`prediction_unit()` 是 inter 路径的关键入口。

其逻辑大体是：

```text
prediction_unit():
  若 mergeFlag:
    merge_data()
  否则若 IBC:
    写 ref_idx / mvd / mvp
  否则:
    写 inter_pred_idc
    写 affine_flag / smvd_mode
    分别写 L0/L1 的 ref_idx、mvd、mvp
```

这说明普通 inter 写出顺序大致是：

1. inter 方向
2. affine / SMVD 等工具标志
3. 参考索引
4. MVD
5. MVP 索引

### 10.1 merge 系列

`merge_data()` 又会继续分流：

- 普通 merge
- affine merge
- MMVD
- GEO
- CIIP
- IBC merge

对应的核心函数包括：

- `merge_idx()`
- `mmvd_merge_idx()`
- `subblock_merge_flag()`
- `ciip_flag()`

这说明 merge 虽然上游在模式决策时已经选好了，但比特流层依然要精细区分不同 merge 族工具的语法。

### 10.2 运动信息语法

`CABACWriter` 对 inter MV 相关语法的处理重点包括：

- `ref_idx()`
- `mvp_flag()`
- `mvd_coding()`
- `imv_mode()`
- `affine_amvr_mode()`

其中 `mvd_coding()` 是典型的 CABAC 低层写法：

- 先写 `abs_mvd_greater0_flag`
- 再写 `abs_mvd_greater1_flag`
- 再写剩余绝对值和符号位

它本质上把一个运动差分向量拆成多层二值语法元素。

## 11. 残差相关语法

### 11.1 `cu_residual()`

这是 CU 残差层入口，负责决定：

- root cbf
- SBT
- transform tree 递归
- residual 相关工具语法

### 11.2 `transform_tree()`

`transform_tree()` 负责递归遍历 TU 树：

- 若当前 TU 继续分裂
  - 递归进入子 TU
- 否则
  - 写 `transform_unit()`

这与上层 `coding_tree()` 类似，只不过对象从 CU 树变成了 TU 树。

### 11.3 `transform_unit()`

这个函数会写：

- `cbf_comp()`
- `cu_qp_delta()`
- `cu_chroma_qp_offset()`
- `joint_cb_cr()`
- 各分量 `residual_coding()`

它是 TU 级语法的总组织器。

### 11.4 `residual_coding()`

这是系数编码的核心入口，主要做：

1. 写 `ts_flag()`
2. 初始化 `CoeffCodingContext`
3. 写最后一个非零系数位置 `last_sig_coeff()`
4. 按子块写显著性和系数值

它会根据配置和 TU 状态处理：

- transform skip
- depQuant
- sign data hiding
- LFNST / MTS 相关约束

因此它是 CABACWriter 里另一个热点函数。

### 11.5 相关辅助函数

系数路径还包括：

- `residual_coding_subblock()`
- `residual_codingTS()`
- `residual_coding_subblockTS()`
- `mts_idx()`
- `residual_lfnst_mode()`
- `isp_mode()`

这说明 CABAC 残差写出不是单一算法，而是根据工具组合切换不同路径。

## 12. 滤波相关语法

除了树结构、预测和残差，`CABACWriter` 还负责若干 CTU 级滤波语法。

### 12.1 SAO

相关函数：

- `sao()`
- `sao_block_pars()`
- `sao_offset_pars()`

这些函数负责：

- SAO merge 标志
- SAO 类型
- 各分量 offset 参数

### 12.2 ALF / CCALF

相关函数：

- `codeAlfCtuEnabled()`
- `codeAlfCtuEnabledFlag()`
- `codeAlfCtuFilterIndex()`
- `codeAlfCtuAlternative()`
- `codeCcAlfFilterControlIdc()`

这些函数体现出：

- `CABACWriter` 不只编码块级语法
- 也统一承载 in-loop filter 的 CTU 级语法输出

## 13. 辅助编码原语

类里还有一组通用编码辅助函数：

- `unary_max_symbol()`
- `unary_max_eqprob()`
- `exp_golomb_eqprob()`
- `xWriteTruncBinCode()`

这些函数的作用是：

- 把高层 syntax element 映射成规范要求的 binarization 形式

也就是说，`CABACWriter` 处在：

- 上层“语义对象”
- 下层“单 bin 编码”

之间的中间层。

## 14. 设计特点总结

从设计上看，`CABACWriter` 有几个很鲜明的特点。

### 14.1 语法组织与算术编码分离

`CABACWriter` 不直接实现 arithmetic engine，而是把：

- 语法树遍历
- 上下文选择
- binarization

和：

- 实际 bin 编码

分离开来。

这是很典型也很合理的分层。

### 14.2 强递归结构

类中最核心的两条递归链是：

- `coding_tree()`
- `transform_tree()`

这说明它的实现天然跟随 VVC 的块树结构，而不是扁平遍历。

### 14.3 既服务“真实写码流”，也服务“比特估计”

由于 `CABACWriter` 依赖抽象的 `BinEncIf`，同一套函数既可以：

- 连到真实 bitstream，输出码流
- 也可以连到 estimator，用于 RD 比特估计

这点在 vvenc 里非常重要，因为很多 RD 流程都复用了同一套 CABAC 写出逻辑来估 bit。

### 14.4 条件分支极多，但都围绕规范语法

`CABACWriter` 代码看起来分支很多，但这些分支本质上都在回答：

- 当前工具是否启用
- 当前块是否满足语法条件
- 当前 syntax element 是否需要发送

所以它的复杂度主要来自标准语法本身，而不是实现额外加了太多抽象。

## 15. 一句话总结

`CABACWriter` 可以概括为：

> vvenc 中负责按 VVC 语法顺序递归遍历编码结果、选择上下文模型并驱动底层 CABAC/bin 编码输出的核心语法写出类。

如果说：

- `EncCu` / `InterSearch` / `IntraSearch` 决定“怎么编码更优”
- `BinEncoder` 决定“bin 怎么算术编码”

那么 `CABACWriter` 负责的就是：

- “这些已经确定的编码决策，应该按什么语法、什么上下文、什么顺序被写出去”
