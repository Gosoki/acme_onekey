# acme_onekey

一个给 **Debian / Ubuntu** 用的 acme.sh 一键脚本：**DNS API 托管方式**申请证书，签完就一直自动续期，同一个脚本还能继续管理（查看 / 续期 / 换路径 / 吊销 / 卸载）。

全程交互式，带防呆：**已存在的证书文件不会被默默覆盖**。

---

## 特性

- **DNS-01 托管签发**：不占用 80 / 443 端口，服务不用停，支持**泛域名** `*.example.com`
- 支持解析商：**Cloudflare**、**阿里云 DNS**、**腾讯云 DNSPod**、**DNSPod 国内版**
- 自动安装 acme.sh 及依赖（`curl` `socat` `openssl` `cron` `ca-certificates`），并确认 `cron` 服务在跑
- **自定义证书存放目录**，续期后新证书自动复制到该目录并执行你指定的重载命令
- **防呆**：
  - 目录里已有证书文件 → 默认不覆盖，先让你换目录，要覆盖必须二次确认
  - 目标路径已被其它域名占用 → 直接拒绝
  - 域名已签发过 → 不会默认重签（避免撞 CA 频率限制），只提供「强制重签 / 仅重新部署 / 取消」
  - 路径必须是绝对路径，禁止 `/`、`/etc`、`/usr` 等系统顶级目录
  - 域名格式校验、吊销双重确认、卸载双重确认
- **凭据只输一次**：DNS API 密钥由 acme.sh 保存，续期自动读取；再次申请时可选择复用
- 默认 **ECC secp256r1** + **Let's Encrypt**，可在菜单里切到 ZeroSSL / Buypass

---

## 安装 / 使用

```bash
# 下载并运行（需要 root）
wget -O acme-onekey.sh https://raw.githubusercontent.com/<your-name>/acme_onekey/main/acme-onekey.sh
bash acme-onekey.sh
```

或者：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/<your-name>/acme_onekey/main/acme-onekey.sh)
```

首次运行会把脚本装到 `/usr/local/bin/acme-onekey`，**之后直接敲这个命令就能进管理菜单**：

```bash
acme-onekey
```

---

## 菜单

```
 1) 申请新证书（DNS API 托管）
 2) 查看已签发证书           # 域名、CA、到期时间、部署路径、重载命令
 3) 续期证书                 # 全部检查 / 强制续期单个
 4) 吊销并删除证书           # 吊销 + 移除 + 可选删除部署目录里的文件
 5) 修改证书存放路径 / 重载命令
 6) 检查自动续期任务（cron）  # 缺失可一键修复
 7) 切换默认 CA
 8) 更新 acme.sh
 9) 卸载 acme.sh
 0) 退出
```

---

## 申请流程（菜单 1）

1. 输入主域名 → 询问是否同时签 `*.域名`
2. 选解析商，填 API 凭据（已保存过的会问你要不要复用）
3. 输入证书存放目录，默认 `/etc/acme-onekey/certs/<域名>`（目录权限 `700`）
4. 输入续期后的重载命令，例如 `systemctl reload nginx`，**可留空**
5. 确认信息 → 开始签发（等 DNS 记录生效，通常 1~3 分钟）

签完在你指定的目录下会得到：

| 文件 | 说明 |
|---|---|
| `private.key` | 私钥 |
| `fullchain.cer` | 完整证书链（**Nginx / Caddy / Xray 用这个**） |
| `cert.cer` | 域名证书（不含中间证书） |
| `ca.cer` | 中间证书 |

Nginx 示例：

```nginx
ssl_certificate     /etc/acme-onekey/certs/example.com/fullchain.cer;
ssl_certificate_key /etc/acme-onekey/certs/example.com/private.key;
```

> 注意：证书目录权限是 `700`（仅 root 可读）。如果你的服务以非 root 用户读取证书，请把该服务用户加入相应组或自行调整权限。

---

## 各解析商 API 凭据怎么拿

### Cloudflare（推荐用 API Token）

进入 **My Profile → API Tokens → Create Token**，用 *Edit zone DNS* 模板，权限至少：

- `Zone / Zone / Read`
- `Zone / DNS / Edit`
- Zone Resources 选中你的域名

脚本会问 `CF_Token`，另外两项 `CF_Account_ID` / `CF_Zone_ID` **可以留空**。

也可以选 Global API Key 模式，填 `CF_Key` + `CF_Email`（权限过大，不推荐）。

### 阿里云 DNS

RAM 访问控制里创建用户，授权 `AliyunDNSFullAccess`，得到 `Ali_Key`（AccessKey ID）和 `Ali_Secret`（AccessKey Secret）。

### 腾讯云 DNSPod

腾讯云控制台 → 访问管理 → API 密钥管理，授权 `QcloudDNSPodFullAccess`，得到 `Tencent_SecretId` / `Tencent_SecretKey`。

### DNSPod 国内版

DNSPod 控制台 → 用户中心 → API 密钥 → 创建密钥，得到形如 `12345` 的 ID 和一串 Token，分别对应 `DP_Id` / `DP_Key`。

> 域名必须在对应账号下托管解析，否则会签发失败。

---

## 自动续期是怎么保证的

- acme.sh 安装时会写入 crontab，**每天检查一次**，证书剩余不足 30 天时自动续签
- 续签用的 DNS API 凭据保存在 `/root/.acme.sh/account.conf`，无需再次输入
- 部署路径和重载命令记录在 `/root/.acme.sh/<域名>_ecc/<域名>.conf`，续签后 acme.sh 会**自动把新证书复制到你指定的目录并执行重载命令**

也就是说：**跑完一次就不用再管了。**

自查：

```bash
acme-onekey        # 菜单 6，检查 cron 任务与 cron 服务，缺了能一键修复
crontab -l | grep acme.sh
tail -f /root/.acme.sh/acme.sh.log
```

⚠️ 以下操作会**中断**自动续期，请注意：

- 删除 `/root/.acme.sh/`
- 删除或改坏 crontab 里的 acme.sh 任务
- 停用 `cron` 服务
- 撤销 / 重置 DNS API 密钥（续期时鉴权会失败）
- 直接手动往证书目录里塞证书 —— 那不是 acme.sh 管理的，不会续

---

## 常见问题

**签发失败，提示 DNS 校验超时**
API 密钥权限不足，或域名没在该账号下托管。手动排查：

```bash
/root/.acme.sh/acme.sh --issue --dns dns_cf -d example.com --debug
```

**提示 rate limit / too many certificates**
Let's Encrypt 对同一主域名有签发频率限制（每周若干张）。别反复「强制重签」——已有证书直接用菜单 3 续期即可，或到菜单 7 换成 ZeroSSL。

**证书签好了但服务还是旧证书**
重载命令没配或没生效。菜单 5 重新设置重载命令，或手动 `systemctl reload nginx`。

**想换存放目录**
菜单 5，不要手动 `mv`——手动移动后 acme.sh 续期仍会往旧路径写。

**我已经用过别的 acme.sh 脚本**
本脚本不会重装已存在的 acme.sh，也不会动你已有的域名配置，可以直接用来管理。

---

## 卸载

菜单 9。会删除 acme.sh、cron 任务和 `/root/.acme.sh`（含全部证书与账户信息）。
已部署到你自定义目录里的证书文件**会保留**，但从此不再自动更新。

---

## 说明

- 仅支持 Debian / Ubuntu（依赖 `apt-get` 和 `systemd` 的 `cron`）
- 需要 root 权限
- 只做 DNS-01 模式；如需 HTTP-01（无 DNS API 时用 80 端口验证），请直接使用 acme.sh 原生命令

## 致谢

- [acmesh-official/acme.sh](https://github.com/acmesh-official/acme.sh) —— 本脚本的核心
- [yonggekkk/acme-yg](https://github.com/yonggekkk/acme-yg) —— 交互式一键脚本的思路参考

## License

GPL-3.0，见 [LICENSE](LICENSE)。
