# App 创意工坊数据层与导出

2026-11-12。**未在真机上验证**，下面的行为依据源码和单元测试，真机要看的步骤在文末。接口以 [Worker v1 合同](../../services/share-worker/docs/workshop-api.md) 为准，Worker 一侧的实现见 [workshop-worker.md](workshop-worker.md)。本文记录 App 侧数据层（`app/lib/workshop/`）、伙伴包的完整性检查与换包门、以及导出和投稿的约定。

## 目录与缓存

目录更新保留已经知道的撤回与 `blockedVersions`：新响应不能把已有被禁版本重新变成可安装状态；这些记录可以在条目与 `withdrawn` 账本之间迁移。未知 kind 只验证通用元数据，允许未来种类使用更大的包或新的许可证标识，仍显示「不支持」，不能投稿、下载或调用当前安装器。

`downloadDirectory` 必须是本模块专用的 App 私有目录。同一 App isolate 内，多个 repository 按规范化绝对 URI 字符串共享串行队列，防止新 provider 清理仍被旧安装器读取的 ZIP。调用方须统一使用同一路径；这个键不解析所有文件系统别名，也不是跨 isolate 或跨进程锁。缓存保留一个可续传资源槽位；选择另一个 SHA 后，只删除本模块格式的旧 `<sha>.zip` / `<sha>.zip.part` 文件，不递归删除其他目录。选择另一资源会放弃前一资源尚未完成的续传。清理失败明确返回存储错误。HTTP 连接建立超时后若请求对象晚到，会立即 abort；设置请求头 / 发送正文失败也关闭请求。

同一 App isolate 内，按相同方式规范化的 `cacheFile` 共享目录事务队列与最新已知撤回集合，队列覆盖请求、解析和落盘；旧客户端不能用自己的旧内存副本覆盖新客户端刚记录的撤回。调用方同样须统一缓存路径，不得依赖跨 isolate 的内存共享。切换 Worker origin 会重新核对磁盘缓存来源。暂停 companion 时主目录会隐藏 companion 行，安装和已装状态因此先看明确开关，报告 `workshop_companion_disabled`；已装撤回标记独立保留。

首次读缓存遇到存储错误且尚无健康内存副本时，下一次串行目录事务可以重试磁盘读取；同规范路径的新客户端也能重试，成功读取会清除旧的 `cache_storage`。若网络已取得较新目录，即使随后保存失败，也保留该内存副本和已知撤回，不再从旧磁盘覆盖它。离线读取恢复只供标记为 `stale` 的浏览，`requireFresh` 的安装门继续拒绝离线。

## 数据层入口

`WorkshopClient(origin, cacheFile, http?)` 需要调用方明确给定 HTTPS Worker origin 和 App 私有缓存文件，没有隐藏的生产部署地址。`WorkshopRepository(client, packages, downloadDirectory, appVersion, freeBytes?)` 编排下载和安装。生产包存储使用 `LocalWorkshopPackages(pets, companion)`，内部调用既有的 `PetLibrary.install` 与 `CompanionPackStore.install`。

`cachedCatalog()` 只读可用缓存，不发 HTTP；与目录刷新共用同一事务队列及缓存加载逻辑。有副本时返回原 `fetchedAt`、`cacheIssue` 和 `stale=true`，没有可用副本时返回 null，缓存问题仍可从 client 的 `cacheIssue` 读取。它不会更新核验时间、替换较新的内存副本或放松已知撤回检查。页面可以先展示这个结果，再调用 `catalog()` 刷新；安装仍须走既有强制刷新门。

`catalog(requireFresh: false)` 尝试刷新，可在网络失败时返回 `stale: true` 的缓存并附 `refreshError`。`requireFresh: true` 不允许回退；安装前和下载后都用此模式。结果有 `cacheIssue`，客户端的同名 getter 也保留没有可用缓存时的磁盘问题。缓存只含公开目录、ETag、origin 和抓取时间，不含账号或投稿状态。304 只在已有同 origin 有效缓存时接受。目录声明的 kind、版本、`minApp`、内容寻址 URL、SHA 和大小均检查；未知 kind 保留为不支持类型，不传给宠物安装器。

服务端开关默认开；明确关闭时返回 `workshop_upload_disabled` / `workshop_companion_disabled`。原来已装内容不会因联网失败或服务端关闭而被自动删除。客户端完成一次网络往返后发生的撤回无法提前获知，已下载副本也不能远程追回；这不是「离线目录仍可授权安装」的理由。

版本比较遵循 Worker 的 80 字符 SemVer 合同，不接受 build metadata。源码既有的 `AppVersion` 使用 int，Worker 的数字标识可超过 int64，所以本层比较数字串的长度和字典序，不损失精度。设备版本可带 Android build 后缀，比较前去掉 `+…`。

## 下载、安装与本地版本

下载复用 `ApkDownloader`，沿用 Range 续传、取消、重试与 SHA-256。包装传输只接受本次固定的内容寻址 URL，禁止跳转，严格校验 Content-Range 和总长；没有 Content-Length 时也在超过目录 `size` 前中止流。有界正文使用保留上游取消传播的 `Stream.map`，避免额外的异步生成器在等待下一块时阻碍取消；这不承诺网络或文件系统立即完成清理。

空间预检的预算为 ZIP、64 MiB staging、伙伴 runtime 的复制量和 4 MiB 余量。Android 既有的 update info 提供 `cacheDir` 可用空间；调用方可注入与目标目录同文件系统的更精确探针。预检不预留磁盘空间，未知剩余空间也不表示「足够」。本层直接取得的存储错误数字码 28、122 映射成 `workshop_no_space`，其他或未知码为 `workshop_storage`。既有下载器把写入失败归并为 storage，丢失原 errno，因此本层在该失败后再查空间：预算不足返回 `workshop_no_space`，探针不可用或预算足够仍返回 `workshop_storage`。该探针只说明查询时预算是否够用，不能证明刚才的写入失败原因，也不能排除已经丢失的配额错误。

伙伴解压写入失败时保留原始的存储错误类型、errno 和栈，再由既有映射给出 `no_space` 或 `storage`。写入失败后关闭输出流，以及失败事务最后关闭输入流，都不能遮蔽主错误；正常写入后的输出 close 失败仍为 `storage`，非存储的提取错误仍为 `notAPack`。生产路径在 `compute` isolate 里提取；仅测试构造器可替换一个输出文件流边界，并在当前 isolate 执行同一安装事务。依赖的控制流按官方 archive v4.6.0 标签 commit `3852d7e402a2a796d3f2af00ac3c28f129c0bb78` 的源码核对。

下载成功后的次序是：核长度、再次查询安装空间、以 `requireFresh` 取得并核对当前条目、同步检查取消，然后交给 `packages.install`。空间不足会优先失败，并且不会发出最终目录请求；正常成功仍有下载前、交接前两次目录刷新。最终目录请求排在可能暂停的空间查询之后，但目录刷新与包目录提交不是一个原子事务。安装器接手后发生的撤回不取消这次在途安装；后续安装仍须通过新的目录检查。

每个工坊安装目录里有 `.workshop-source.json`，仅记录 kind、id、version、SHA、origin。它在 staging 中写好，随资源目录一起切换，没有先装好资源再补数据库的双写窗口。手工导入没有收据，因此覆盖后不再冒充旧工坊版本。宠物本地 ID 仍走现有的 `userPetIdFor`；网络身份 `(kind, id)` 与本地目录名分别处理。两个网络 ID 映射到一个目录、或者伙伴单槽位已有别的角色时，默认 `workshop_install_conflict`；调用方显式确认后传 `replaceExisting: true`。

提交切换前在原安装器队列内再次核对收据。同版不同 SHA 拒绝，已装新版本不被旧下载降级。卸载传入此前观察到的收据；期间被替换后，旧卸载请求失败，不删除新包。`states(catalog)` 为公开条目给出 `installed`、`updateAvailable`、`installedWithdrawn`、`unavailable`。`installedStates(catalog)` 保留全部已装资源，即使撤回后公开条目已消失，也明确显示被撤回且仍可卸载；来自其他 Worker 的收据不会被当前目录误认。卸载不访问记忆、聊天、语音或论坛身份。

宠物列表按条目隔离可识别的收据或包读取问题。`PetLibrary.workshopReceipts()` 以 localId 为 Map 键，每条值为 `(receipt: WorkshopReceipt?, issue: String?)`；无收据的普通本地导入仍不进入工坊列表。共同结果类型 `WorkshopLocalEntry` 包含两种情况：`WorkshopInstalled` 保留非空可信 receipt 和可选 issue，`WorkshopInstallationIssue` 只有本地标识和问题，不伪造网络身份。

`installed()` 与 `installedStates(catalog)` 都保留错误行；公开 `states(catalog)` 只用可信收据匹配。收据无效返回 `workshop_install_record`，收据读取失败返回 `workshop_storage`，均无可信 receipt；包格式错误返回 `workshop_pet_bad_pack`、包读取失败返回 `workshop_storage`，仍保留已读到的有效收据。PetLibrary 的根目录获取、恢复或枚举失败仍使整个列表失败；`StateError` 等未识别异常从 `PetLibrary` 继续向调用方传播，repository 沿用既有整体错误映射，仍以整次查询失败结束。

有效收据对应坏包时，`WorkshopInstalledState.installed.issue` 与远端 `unavailable` / `installedWithdrawn` 分开保留，仍可按原收据围栏卸载；观察后若被替换，旧卸载请求拒绝删除新包。工坊 `uninstall` 接受共同条目类型，但无可信收据的错误行会在调用包存储删除前以 `workshop_install_record` 拒绝，不能从其 localId 猜测远端身份。

Companion 槽位的列表读取将预期的收据、存储和恢复错误经既有映射保留为无可信 receipt 的 `WorkshopInstallationIssue`，不阻止已读取的健康 Pet 行返回。这包括底层已转换为 `CompanionPackException` 的停止读者失败；未被底层转换而直接逸出的程序错误仍由 repository 整体映射，使整次查询失败。成功收据还须 `kind == 'companion'`，否则报 `workshop_install_record`。此隔离只用于列表，不改 store 的恢复、严格安装 / 卸载围栏，也不增加全 pack 完整性扫描。

工坊伙伴包只有 character，必须先有本机钉死摘要的 runtime；缺失返回 `workshop_runtime_missing`，本层不自动下载。来自工坊的角色经现有安装器及完整性门；原有的本地导入仍保留其调用方式。

## 伙伴完整性与换包门

`CompanionPackStore.unavailableReason()` 返回 `Future<String?>`，null 表示文件完整性门通过。稳定原因有：

- runtime：`companion_runtime_missing`、`companion_runtime_incomplete`、`companion_runtime_mismatch`。
- index：`companion_missing_index`、`companion_bad_index`。
- 模型与引用：`companion_no_model`、`companion_missing_model`、`companion_bad_model`、`companion_bad_reference`、`companion_missing_reference`、`companion_missing_texture`、`companion_missing_file`、`companion_bad_json`、`companion_bad_moc`、`companion_moc_version`。
- 其他：`companion_unsafe_path`、`companion_too_large`、`companion_changed`、`companion_storage`。

检查内容为整套 runtime digest、core / framework / shaders、index 所列文件、model3 的 moc / 纹理 / 物理 / pose / 表情 / 动作引用、严格 JSON 与 moc 格式枚举上界 6。它不运行 Core，不证明模型一致性、GPU 支持或实际画面；这些要由舞台加载和真机验证决定。

同 root 的 store 实例共享队列、`revision` 与 `revisions`。`beforeChanges(Future<void> Function() stopReaders)` 注册换包门，返回注销函数。事务先发布开始 revision，await 每个门关闭读取者，再修改目录；门失败返回明确的 `companion_readers_busy`，不移动 live。成功或失败均发布结束 revision。门内不要等待同 store 的操作，否则等待本身所持的队列会死锁。读者应先订阅 revision，再 await `unavailableReason`，检查前后 revision 一致才使用结果。

悬浮窗一侧的接线顺序：在 `beforeChanges` 中 await 原生 `configure(float: null)` 完成 WebView 销毁，再 await `server.close`；`revisions` 驱动异步重新检查与重建，用自己的检查代次与 revision 丢弃晚到的结果。细节见 [companion-floating.md](companion-floating.md)。`pack.previous` 在进程中断后由下一次操作恢复；删除先 rename 到 trash，避免半删与旧备份复活。

## 导出

`PetLibrary.exportZip(id, destination, publicId?, author?, license?, source?)` 从已解析的行为字段重建 schema-1 manifest，只带引用的 PNG；未知键、额外文件与收据不会携带。产物重新通过同一 `PetPackValidator`。投稿可显式覆盖公开 ID 与署名，使包内外 metadata 一致。

`CompanionPackStore.exportZip(destination, name?, persona?, author?, license?, source?)` 只从 pack / character 取选定模型和引用资源，重建 Cubism 数据与适配表。runtime、index、收据、未知配置、备注、UserData、动作事件文本、声音与 Sound 引用不导出；原始模板里明确命名的 LICENSE / COPYING / NOTICE 文本保留。index 由安装器重建。适配表保留参数、表情、动作、区域、尾巴、姿态与取景数据。文件系统链接拒绝。

默认名字是中性的 `Companion`，无人设。只有调用方为本次导出显式传入 name / persona 才携带，不自行读取用户偏好。代码不读取 character 目录以外的记忆、聊天、voice-sample 或安全凭据存储。对任意作者素材内嵌文字的语义不能给出程序化保证；本层保证不遍历这些个人数据源，并拒绝通过未知 JSON 字段夹带它们。投稿页面仍须让用户查看最终名单。

`preparePet` / `prepareCompanion` 接受 `WorkshopPublication`，导出后返回 `WorkshopPreparedUpload(file, metadata, files)`，其中 `files` 是实际 ZIP 成员清单。目标文件已存在时拒绝覆盖。

公共 metadata 可含 `description` 与 `tags`：简介省略时为空字符串，非空时最多 512 码点；标签省略时为空列表，最多 8 条，每条最多 32 码点且非空白，原字符串必须唯一，不做大小写或 Unicode 归一化。非空值沿用既有文本门，保留原文字及标签顺序；null 和错误类型拒绝。`WorkshopMetadata` 持有不可变的标签副本，`WorkshopPublication.withArchive`、目录、缓存和投稿保留这两个字段，空值序列化时省略。它们是展示元数据，不嵌入导出的 ZIP；导出器仍只接收原有的明确字段。

导出在 App 拥有者 isolate 里先解析目标父目录的真实路径；宠物和伙伴资源库随后共享一个串行导出队列，所有目标都排队，不按 URI 拼写拆分。队列覆盖 `compute`、最终提交及私有 staging 的清理，因此文件系统视为同一目标的不同大小写拼写也不会同时提交。完成 staging 后再次检查目标不存在，冲突返回 `workshop_export_exists`；失败不会阻塞之后的队列项。

不同目标也会等待前一项完成，资源库可能因此更久持有自己的队列；尚未完成的写入会延迟所有后续导出。写入回调只应生成本次 staging，不得递归等待另一次导出。该并发承诺限于同一 App isolate 的这些导出 API，不是跨 isolate、跨进程或外部文件系统写入者之间的 no-replace 原语；最后一次检查与普通 rename 之间仍不具备这种原子保证。

伙伴导出对每张 PNG 复用 `pngIntact` 的完整校验：8 MiB 文件、每边 4096、16 MiB 解码后 RGBA、CRC / IDAT 和像素解码。超界或损坏在 prepare 返回前以稳定错误拒绝，不缩小一般本地导入范围，也不放宽 Worker。导出的 JSON 成员仍限 1 MiB；空的许可 / notice 文件省略。缺少 `character.model` 时沿用舞台的 index 首模型顺序，不能因为另一个模型路径更浅而换角色。

## 投稿与凭据

`WorkshopCredential.forConsentedWorker(worker, forum, userApiKey, disclosureAccepted)` 只表示外层已完成确认，不会替用户获得授权。Key 只用于本次 API 请求；不进入缓存、收据、JSON 正文或错误信息。工坊 origin 必须与确认目标相同，capabilities 的 `forumOrigin` 必须与该账号来源相同。真实传输禁止重定向，不把 Key 发给下载裸桶或任意网址。

所有作者请求还携带 `X-Workshop-Forum-Origin`，值为该 credential 的规范化论坛 origin。Worker 在请求论坛前再次与配置严格比较，缺失或不等返回 `409 / workshop_forum_origin`；断言不选择上游地址。capabilities 之后的配置变化因此不能靠前一次检查放行。收到该错误应重新核对账号来源与转交目标，不自动把 credential 的来源改成服务器新值；公开查询不携带 Key 或此断言。

Worker 目标、credential、capabilities 和投稿 owner 响应共用 `workshopOrigin`。它先执行 HTTPS、无 userInfo / query / fragment、路径为空或单斜杠的既有门，再重建 origin；普通 ASCII 主机转小写、默认 443 消去、根路径省略。普通 IPv6 按地址值输出最短小写十六进制段，并压缩最长的至少两段连续零；并列时取左侧。展开式与压缩式因此相等，不同地址仍不同。zone 标识和 IPvFuture 不在该规范化支持承诺内；其他输入门没有因此放宽。capabilities 与单条 / 分页投稿响应的来源比较全部保留。

作者 API 为 `createSubmission`、`upload`、`submit`、`submission`、`submissions`、`withdraw`、`report`。create / submit 要求单独显式传 `rightsConfirmed: true`，不能因为拿到一个目录条目就推断用户声明有权分享。`requestId` 由调用方在操作前保存；`newRequestId()` 给出随机的 32 位十六进制值。相同 `requestId` 重试创建有服务端幂等保证；pending / approved / rejected / withdrawn 不被便利方法重新上传。

上传先持有精确、受大小限制的字节快照并校验 SHA，再发送同一快照，防止哈希后文件被替换。状态、审核与撤回原因均保留；分页是服务端的实时视图，不承诺同一 revision 的快照。投稿的 approved 表示审核历史，当前是否公开以重新验证的目录为准，不能只据这个历史状态显示「正在公开」。

`upload` / `submit` 可接收 `onProgress(sent, total)`，单位为已交给传输层的字节和本次精确快照的总字节。真实 HTTP 先报告 0，再按最多 64 KiB 的块提交并 flush 后报告进度；完整 body 泵送与响应头共用一次超时预算，超时会 abort，迟到的 flush 不能继续写入或报告进度。到达 total 只说明字节已交给传输层，不表示服务端已接收、验证、进入 pending 或批准；结果必须等方法完成并读取响应。未实现可选上传接口的旧 HTTP 替身只报告 0 与取得响应后的 total；它不是吞吐测量。幂等返回已有非 draft 投稿时没有新的上传，也不伪造上传进度。

超时、连接丢失或无法解析的写入成功响应将 `resultUnknown` 标为 true；对有投稿 ID 或 requestId 的操作，调用方应重查或保留原 requestId 恢复，不能声称未提交。便利方法 `submit` 包含创建草稿和上传两个阶段：草稿创建成功后，上传前的 capabilities 查询或文件校验仍可能失败。这类失败的 `resultUnknown` 可以是 false，但不能据此断言整次操作未产生远端记录。任何失败都应保留原 requestId；需要立即保存投稿 ID 的页面可拆开调用 `createSubmission` 与 `upload`。

举报没有投稿创建的 requestId 幂等合同，也没有作者侧举报查询接口。举报结果未知时不得自动按「肯定失败」重复发送。客户端本身不自动重试这些写操作。撤回与举报在暂停新投稿时仍可调用。App 不保存管理员 Key，不实现运维审核页。

User API Key 的本地格式门与 Worker 一致，为 1–512 个可见 ASCII 字符。本人列表允许 100 条合法多字节记录，所以该接口单独采用 8 MiB 有界响应门（与 Worker 状态对象上限一致）；其他普通 JSON 请求仍限 1 MiB。最大页不是无界读流。

## 测试覆盖

- `app/test/workshop/`：`workshop_models_test.dart`（模型与版本比较）、`workshop_client_test.dart`（目录缓存与离线重启、撤回与 `blockedVersions`、重定向不带 Key、凭据与投稿 API、分页与响应上限）、`workshop_http_test.dart`（超时后晚到的请求、请求头失败时关闭请求）、`workshop_repository_test.dart`（续传 / 校验 / 取消、低空间、下载中撤回、离线浏览与拒绝离线安装、已装撤回状态、卸载、ENOSPC 映射、伙伴导出的 PNG 门）、`workshop_export_test.dart`（导出目标队列、提交处再次检查目标、悬空链接）。
- `app/test/workshop/workshop_installed_test.dart`：混合健康条目、坏收据、坏包与无收据本地包，核对逐条错误、可信身份匹配及有效收据的卸载围栏；单条读取失败在委托边界注入，根目录失败和意外 `StateError` 继续传播。
- `app/test/pets/pet_workshop_export_test.dart`：宠物导出。
- `app/test/companion/companion_workshop_test.dart`：伙伴的完整性门、解压写入失败时的存储错误映射（部分写入、errno 28 / 5、主错误加 close 失败、仅 close 失败、归档错误，并核对旧包与收据逐字节不变、staging 清理）、导出往返与隐私哨兵、换包门（停止读取者、中断恢复、同 root 共享队列与 revision）。这几项使用实际 `ArchiveFile`、真实临时 ZIP / 文件及 `FileHandle` 委托；注入失败不是实盘耗尽测量。
- `app/test/workshop/workshop_export_contract_test.dart`：显式设置 `DSH_WORKSHOP_CONTRACT_OUT` 到空目录时，保存真实 App 导出的 pet、companion、pet-unicode、companion-unicode 四份 ZIP 和 metadata，供同一协议版本的 Worker 校验；未设置时仍做 App 往返测试，不留下文件。Unicode 用例保留引用路径及原始资源字节。合成 MOC 仅用于格式合同，不能运行 Core。跨运行时往返需要「同一份 App 导出字节被 Worker 接受」的记录才算证据，Node 自行生成的 ZIP 不算。

## 真机上要看的

低空间、断网 / 杀进程后的续传、换包时悬浮窗的销毁重建、已有 runtime 缺失 / 损坏、厂商 WebView / GPU，以及导出后的分享流程。

## 还没有做的

- 工坊的浏览、投稿、审核入口页面。
- 稳定错误码的中英文文案。
- 覆盖具体资源的确认。
- 官方论坛账号读取与首次凭据转交的说明。
- 保存非秘密的 `requestId` / 投稿 ID。
- 安装 / 卸载后的宠物状态刷新与伙伴舞台重载。
