// ==UserScript==
// @name         爱奇艺 Dash 助手
// @namespace    http://tampermonkey.net/
// @version      6.0
// @description  捕获 Dash 链接，自动预加载字幕，支持基于 tvname 的自动命名下载，支持一键复制所有 Dash。
// @author       Gemini
// @match        *://www.iqiyi.com/*
// @grant        GM_download
// @grant        GM_setClipboard
// @run-at       document-start
// @license      MIT
// ==/UserScript==

(function() {
    'use strict';

    // 状态存储
    const state = {
        captured: new Set(), // 存储去重后的 Dash URL
        items: []            // 存储详细信息 {id, dashUrl, hasSub, srtUrl, status, filename}
    };

    // --- CSS 样式 ---
    const styles = `
        #iqy-dash-trigger {
            position: fixed;
            top: 150px;
            left: 0;
            z-index: 99999;
            background: rgba(0, 200, 0, 0.8);
            color: white;
            padding: 8px 12px;
            border-radius: 0 20px 20px 0;
            cursor: pointer;
            font-size: 12px;
            box-shadow: 2px 2px 5px rgba(0,0,0,0.3);
            transition: all 0.3s ease;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            user-select: none;
        }
        #iqy-dash-trigger:hover {
            padding-right: 20px;
            background: rgba(0, 220, 0, 1);
        }
        #iqy-dash-panel {
            position: fixed;
            top: 150px;
            left: 60px;
            width: 420px;
            max-height: 500px;
            background: rgba(24, 24, 24, 0.95);
            backdrop-filter: blur(12px);
            border: 1px solid rgba(255,255,255,0.15);
            border-radius: 12px;
            color: #eee;
            z-index: 99999;
            display: none;
            flex-direction: column;
            box-shadow: 0 12px 40px rgba(0,0,0,0.6);
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            opacity: 0;
            transform: translateX(-20px);
            transition: opacity 0.25s, transform 0.25s;
        }
        #iqy-dash-panel.show {
            display: flex;
            opacity: 1;
            transform: translateX(0);
        }
        .panel-header {
            padding: 12px 16px;
            background: rgba(255,255,255,0.08);
            display: flex;
            justify-content: space-between;
            align-items: center;
            border-bottom: 1px solid rgba(255,255,255,0.1);
        }
        .panel-title { font-weight: 600; font-size: 14px; color: #00e090; letter-spacing: 0.5px; }
        .panel-close { cursor: pointer; padding: 4px; font-size: 18px; line-height: 1; opacity: 0.7; }
        .panel-close:hover { opacity: 1; }

        .panel-content {
            flex: 1;
            overflow-y: auto;
            padding: 10px;
            max-height: 380px;
        }
        .panel-content::-webkit-scrollbar { width: 6px; }
        .panel-content::-webkit-scrollbar-thumb { background: #555; border-radius: 3px; }

        /* 列表项 */
        .log-item {
            background: rgba(255,255,255,0.04);
            margin-bottom: 8px;
            padding: 10px;
            border-radius: 6px;
            border-left: 3px solid #666;
            position: relative;
        }
        .log-item.has-sub { border-left-color: #00e090; background: rgba(0, 224, 144, 0.05); }
        .log-item.no-sub { border-left-color: #ff5555; }

        .item-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 6px; }
        .item-title { font-size: 12px; font-weight: bold; color: #fff; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 280px;}
        .item-time { font-size: 10px; color: #888; }

        .item-url-box {
            background: rgba(0,0,0,0.3);
            padding: 4px 6px;
            border-radius: 4px;
            margin-bottom: 6px;
            font-size: 11px;
            color: #aaa;
            word-break: break-all;
            display: -webkit-box;
            -webkit-line-clamp: 1;
            -webkit-box-orient: vertical;
            overflow: hidden;
            font-family: monospace;
        }

        .btn-group { display: flex; gap: 8px; justify-content: flex-end; }
        .action-btn {
            padding: 5px 12px;
            border: none;
            border-radius: 4px;
            font-size: 11px;
            cursor: pointer;
            transition: all 0.2s;
            color: white;
            font-weight: 500;
        }
        .action-btn:hover { transform: translateY(-1px); filter: brightness(1.1); }
        .action-btn:active { transform: translateY(0); }

        .btn-dash { background: #3b82f6; }
        .btn-dl { background: #f59e0b; color: #000; }

        .panel-footer {
            padding: 12px;
            background: rgba(0,0,0,0.2);
            border-top: 1px solid rgba(255,255,255,0.1);
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        .btn-copy-all {
            width: 100%;
            background: #10b981;
            color: white;
            padding: 8px;
            border: none;
            border-radius: 6px;
            cursor: pointer;
            font-size: 13px;
            font-weight: bold;
            transition: background 0.2s;
        }
        .btn-copy-all:hover { background: #059669; }

        .status-tag { font-size: 10px; padding: 2px 5px; border-radius: 3px; margin-left: 5px; background:#444; }
        .has-sub .status-tag { background: rgba(0, 224, 144, 0.2); color: #00e090; }
    `;

    // --- 工具：获取当前页面视频标题 ---
    function getCurrentVideoName() {
        try {
            // 1. 优先尝试从 URL 参数中提取 tvname
            const params = new URLSearchParams(window.location.search);
            const tvname = params.get('tvname');

            if (tvname) {
                // 解码 URI 组件
                return decodeURIComponent(tvname).trim();
            }

            // 2. 如果 URL 没有，尝试 document.title，并清理后缀
            let title = document.title;
            title = title.replace('-电视剧-高清完整版在线观看-爱奇艺', '').replace('-动漫-高清完整版在线观看-爱奇艺', '').trim();
            return title;

        } catch (e) {
            console.warn('获取视频名称失败', e);
            return `视频_${Date.now()}`;
        }
    }

    // --- UI 构建 ---
    function initUI() {
        const styleEl = document.createElement('style');
        styleEl.textContent = styles;
        document.head.appendChild(styleEl);

        const trigger = document.createElement('div');
        trigger.id = 'iqy-dash-trigger';
        trigger.innerHTML = 'Dash<br>0';
        trigger.onclick = () => togglePanel(true);
        document.body.appendChild(trigger);

        const panel = document.createElement('div');
        panel.id = 'iqy-dash-panel';
        panel.innerHTML = `
            <div class="panel-header">
                <span class="panel-title">⚡️ iQIYI Dash 捕获助手</span>
                <span class="panel-close">&times;</span>
            </div>
            <div class="panel-content" id="dash-list-content">
                <div style="text-align:center; color:#666; padding: 30px 0; font-size:12px;">
                    等待捕获...<br>切换集数会自动添加
                </div>
            </div>
            <div class="panel-footer">
                <button class="btn-copy-all" id="btn-copy-all-dash">一键复制所有 Dash 链接</button>
            </div>
        `;
        document.body.appendChild(panel);

        panel.querySelector('.panel-close').onclick = () => togglePanel(false);

        // 绑定全部复制事件
        document.getElementById('btn-copy-all-dash').onclick = copyAllDashLinks;
    }

    function togglePanel(show) {
        const panel = document.getElementById('iqy-dash-panel');
        if (show) {
            panel.style.display = 'flex';
            setTimeout(() => panel.classList.add('show'), 10);
        } else {
            panel.classList.remove('show');
            setTimeout(() => panel.style.display = 'none', 250);
        }
    }

    // --- 核心逻辑 ---

    // 1. 监听网络请求
    function monitorNetwork() {
        const originalOpen = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(method, url) {
            if (typeof url === "string" && url.includes("cache.video.iqiyi.com/dash?tvid=")) {
                handleCapturedUrl(url);
            }
            return originalOpen.apply(this, arguments);
        };

        const originalFetch = window.fetch;
        window.fetch = function(...args) {
            let url = args[0] instanceof Request ? args[0].url : args[0];
            if (typeof url === "string" && url.includes("cache.video.iqiyi.com/dash?tvid=")) {
                handleCapturedUrl(url);
            }
            return originalFetch.apply(this, args);
        };
    }

    // 2. 处理捕获的 URL (关键修改：这里立即获取当前页面标题)
    function handleCapturedUrl(url) {
        if (state.captured.has(url)) return;
        state.captured.add(url);

        const trigger = document.getElementById('iqy-dash-trigger');
        if(trigger) trigger.innerHTML = `Dash<br>${state.captured.size}`;

        // *** 关键点：捕获时锁定当前页面的名称 ***
        // 这样即使后续页面跳转了，这个 Dash 链接对应的文件名依然是它产生时的那个
        const currentName = getCurrentVideoName();

        const itemData = {
            id: Date.now() + Math.random(),
            dashUrl: url,
            hasSub: false,
            srtUrl: null,
            status: 'checking',
            filename: currentName // 保存文件名
        };
        state.items.push(itemData);

        renderList();
        analyzeDashContent(itemData);
    }

    // 3. 预加载并分析 JSON
    function analyzeDashContent(item) {
        fetch(item.dashUrl)
            .then(res => res.json())
            .then(json => {
                try {
                    const data = json.data;
                    const program = data.program;

                    if (program && program.stl && program.stl.length > 0) {
                        let dstl = data.dstl || '';
                        if (!dstl.endsWith('/') && dstl) dstl += '';

                        const subObj = program.stl[0];
                        const srtPath = subObj.srt;

                        if (srtPath) {
                            item.hasSub = true;
                            item.srtUrl = dstl + srtPath;
                            item.status = 'found';
                        } else {
                            item.status = 'none';
                        }
                    } else {
                        item.status = 'none';
                    }
                } catch (e) {
                    console.error('JSON解析出错', e);
                    item.status = 'error';
                }
                updateItemUI();
            })
            .catch(err => {
                console.error('预加载失败', err);
                item.status = 'error';
                updateItemUI();
            });
    }

    // 4. 渲染列表
    function renderList() {
        const container = document.getElementById('dash-list-content');
        if (!container) return;
        container.innerHTML = '';

        // 倒序：最新的在上面
        [...state.items].reverse().forEach(item => {
            const el = document.createElement('div');
            let statusText = '';
            let extraClass = '';

            if (item.status === 'checking') statusText = '检测中...';
            else if (item.status === 'found') { statusText = '包含字幕'; extraClass = 'has-sub'; }
            else if (item.status === 'none') { statusText = '无字幕'; extraClass = 'no-sub'; }
            else statusText = '错误';

            el.className = `log-item ${extraClass}`;

            // 构建 HTML
            let html = `
                <div class="item-header">
                    <div class="item-title" title="${item.filename}">${item.filename}</div>
                    <div style="display:flex;align-items:center">
                        <span class="item-time">${new Date(item.id).toLocaleTimeString()}</span>
                        ${item.status === 'found' ? `<span class="status-tag">SRT</span>` : ''}
                    </div>
                </div>
                <div class="item-url-box" title="${item.dashUrl}">Dash: ${item.dashUrl}</div>
                <div class="btn-group">
                    <button class="action-btn btn-dash" data-url="${item.dashUrl}">复制 Dash</button>
            `;

            // 只有有字幕时才显示下载按钮 (不显示复制链接)
            if (item.status === 'found') {
                html += `<button class="action-btn btn-dl" data-dl="${item.srtUrl}" data-name="${item.filename}">下载 SRT</button>`;
            }

            html += `</div>`;
            el.innerHTML = html;

            // 绑定事件
            const btnDash = el.querySelector('.btn-dash');
            btnDash.onclick = () => copyText(item.dashUrl);

            const btnDl = el.querySelector('.btn-dl');
            if (btnDl) {
                btnDl.onclick = () => downloadFile(item.srtUrl, item.filename);
            }

            container.appendChild(el);
        });
    }

    function updateItemUI() {
        renderList();
    }

    // --- 批量操作逻辑 ---
    function copyAllDashLinks() {
        if (state.items.length === 0) {
            showToast("列表为空");
            return;
        }
        // 提取所有 Dash 链接，用换行符连接
        const allLinks = state.items.map(item => item.dashUrl).join('\n');
        copyText(allLinks, `已复制 ${state.items.length} 个 Dash 链接`);
    }

    // --- 通用工具 ---
    function copyText(text, successMsg = "复制成功！") {
        if (typeof GM_setClipboard === 'function') {
            GM_setClipboard(text);
            showToast(successMsg);
        } else {
            navigator.clipboard.writeText(text).then(() => showToast(successMsg));
        }
    }

    function downloadFile(url, filenamePrefix) {
        // 处理文件名，去除非法字符
        const safeName = (filenamePrefix || 'subtitle').replace(/[\\/:*?"<>|]/g, '_');
        const finalName = `${safeName}.srt`;

        if (typeof GM_download === 'function') {
            GM_download({
                url: url,
                name: finalName,
                saveAs: true
            });
        } else {
            const a = document.createElement('a');
            a.href = url;
            a.download = finalName;
            a.target = '_blank'; // 兼容部分浏览器行为
            document.body.appendChild(a);
            a.click();
            document.body.removeChild(a);
        }
    }

    function showToast(msg) {
        const div = document.createElement('div');
        div.style.cssText = `
            position:fixed; top:50%; left:50%; transform:translate(-50%, -50%);
            background:rgba(0,0,0,0.85); color:white; padding:12px 24px;
            border-radius:8px; z-index:100000; font-size:14px; pointer-events:none;
            box-shadow: 0 5px 15px rgba(0,0,0,0.3); backdrop-filter: blur(4px);
            animation: fadeIn 0.2s ease-out;
        `;
        div.innerText = msg;
        document.body.appendChild(div);

        // 添加简单的淡入动画样式
        const animStyle = document.createElement('style');
        animStyle.innerHTML = `@keyframes fadeIn { from { opacity:0; transform:translate(-50%, -40%); } to { opacity:1; transform:translate(-50%, -50%); } }`;
        document.head.appendChild(animStyle);

        setTimeout(() => {
            div.style.opacity = '0';
            div.style.transition = 'opacity 0.3s';
            setTimeout(() => { div.remove(); animStyle.remove(); }, 300);
        }, 1500);
    }

    // --- 初始化入口 ---
    window.addEventListener('load', () => {
        initUI();
        monitorNetwork();
    });

})();
