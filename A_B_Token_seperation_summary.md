# A/B Token分离系统实现总结

## 概述
成功实现了A/B Token分离系统，允许：
- **存A只能借B，存B只能借A**的借贷规则
- **独立的A/B流动性计算**
- **可切换的分离模式**，支持传统模式和分离模式之间的切换

## 核心功能

### 1. Token分类系统
- `TokenType.TYPE_A (1)`: A类Token，存入后只能借B类Token
- `TokenType.TYPE_B (2)`: B类Token，存入后只能借A类Token
- 未分类Token（默认值0）：在分离模式下不参与A/B计算，在传统模式下正常参与

### 2. 分离模式控制
- `separationModeEnabled`: 布尔值控制是否启用A/B分离模式
- 当启用时，A/B Token有独立的流动性池
- 当禁用时，回退到原始Compound借贷规则

### 3. 独立流动性计算
新增了`getHypotheticalAccountLiquidityInternalSeparated`函数，返回：
- A类流动性和shortfall
- B类流动性和shortfall
- 支持假设性的存取和借贷计算

### 4. 借贷规则更新
- **borrowAllowed**: 在分离模式下，A类Token只能用B类抵押品借出，B类Token只能用A类抵押品借出
- **redeemAllowed**: 在分离模式下，检查赎回是否会导致对应借贷类型的shortfall
- **liquidateBorrowAllowed**: 在分离模式下，根据借贷Token类型检查相应的shortfall

## 管理员功能

### 1. 设置Token类型
```solidity
function _setTokenType(BToken bToken, TokenType tokenType) external returns (uint)
```
只有管理员可以设置市场的Token类型。

### 2. 切换分离模式
```solidity
function _setSeparationMode(bool enabled) external returns (uint)
```
只有管理员可以启用或禁用A/B分离模式。

### 3. 查询分离流动性
```solidity
function getAccountLiquiditySeparated(address account) public view returns (uint, uint, uint, uint, uint)
function getHypotheticalAccountLiquiditySeparated(address account, address bTokenModify, uint redeemTokens, uint borrowAmount) public view returns (uint, uint, uint, uint, uint)
```

## 使用示例

### 设置Token类型
```solidity
// 设置USDT为A类Token
blotroller._setTokenType(bUSDT, TokenType.TYPE_A);

// 设置ETH为B类Token  
blotroller._setTokenType(bETH, TokenType.TYPE_B);
```

### 启用分离模式
```solidity
// 启用A/B分离模式
blotroller._setSeparationMode(true);
```

### 借贷规则
在分离模式下：
- 存入USDT(A类)的用户只能借出ETH(B类)
- 存入ETH(B类)的用户只能借出USDT(A类)
- 只能借出已分类的A/B类Token，不能借出未分类Token
- 未分类Token的抵押品在分离模式下不产生借贷能力

### 混合模式切换
```solidity
// 切换回传统模式，所有Token混合计算流动性
blotroller._setSeparationMode(false);
```

## 好处

1. **独立流动性池**: A/B类Token有独立的流动性管理
2. **灵活切换**: 可以在分离模式和传统模式之间切换
3. **风险隔离**: 不同类型资产的风险相互隔离
4. **向后兼容**: 
   - 传统模式下：所有Token按原规则运行
   - 分离模式下：未分类Token不参与A/B计算，避免意外的借贷风险
5. **精细控制**: 管理员可以精确控制哪些资产可以相互借贷

## 技术实现

1. **存储更新**: 在`BlotrollerStorage.sol`中添加了Token类型映射和分离模式开关
2. **函数分解**: 将复杂的流动性计算函数分解为更小的辅助函数以避免堆栈过深错误
3. **事件日志**: 添加了Token类型设置和分离模式切换的事件
4. **错误处理**: 完整的错误处理和验证机制

## 核心流动性计算逻辑

### 分离模式下的流动性计算规则：
- **A类抵押品** → 可以借出 **B类Token**
- **B类抵押品** → 可以借出 **A类Token**
- 各类型独立计算，互不影响

### 计算公式：
```
A类流动性 = A类抵押品价值 - B类借贷价值
B类流动性 = B类抵押品价值 - A类借贷价值
```

代码已成功编译，所有功能都已实现并可投入使用。 