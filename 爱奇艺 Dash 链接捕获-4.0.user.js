// ==UserScript==
// @name         爱奇艺 Dash 助手 (字幕自动检测版)
// @namespace    http://tampermonkey.net/
// @version      5.0
// @description  捕获 Dash 链接，自动预加载并检测字幕(SRT)，支持一键复制和下载。
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
        items: []            // 存储详细信息对象 {id, dashUrl, hasSub, srtUrl, status}
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
        }
        #iqy-dash-trigger:hover {
            padding-right: 20px;
            background: rgba(0, 220, 0, 1);
        }
        #iqy-dash-panel {
            position: fixed;
            top: 150px;
            left: 60px; /* 在触发器右侧 */
            width: 450px;
            max-height: 500px;
            background: rgba(20, 20, 20, 0.9);
            backdrop-filter: blur(10px);
            border: 1px solid rgba(255,255,255,0.1);
            border-radius: 12px;
            color: #eee;
            z-index: 99999;
            display: none; /* 默认隐藏 */
            flex-direction: column;
            box-shadow: 0 10px 30px rgba(0,0,0,0.5);
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            overflow: hidden;
            opacity: 0;
            transform: translateX(-20px);
            transition: opacity 0.3s, transform 0.3s;
        }
        #iqy-dash-panel.show {
            display: flex;
            opacity: 1;
            transform: translateX(0);
        }
        .panel-header {
            padding: 15px;
            background: rgba(255,255,255,0.05);
            display: flex;
            justify-content: space-between;
            align-items: center;
            border-bottom: 1px solid rgba(255,255,255,0.1);
        }
        .panel-title { font-weight: bold; font-size: 15px; color: #00d084; }
        .panel-close { cursor: pointer; padding: 4px; font-size: 18px; line-height: 1; }
        .panel-content {
            flex: 1;
            overflow-y: auto;
            padding: 10px;
        }
        .panel-content::-webkit-scrollbar { width: 6px; }
        .panel-content::-webkit-scrollbar-thumb { background: #444; border-radius: 3px; }
        
        /* 列表项样式 */
        .log-item {
            background: rgba(255,255,255,0.03);
            margin-bottom: 8px;
            padding: 10px;
            border-radius: 6px;
            border-left: 3px solid #555;
            transition: background 0.2s;
        }
        .log-item:hover { background: rgba(255,255,255,0.06); }
        .log-item.has-sub { border-left-color: #00d084; } /* 有字幕显示绿色 */
        .log-item.no-sub { border-left-color: #ff4d4f; }  /* 无字幕显示红色 */
        
        .item-row { display: flex; justify-content: space-between; align-items: center; margin-bottom: 4px; }
        .item-status { font-size: 11px; padding: 2px 6px; border-radius: 4px; background: #333; color: #aaa; }
        .item-status.success { background: rgba(0, 208, 132, 0.2); color: #00d084; }
        
        .item-url { 
            font-size: 11px; color: #888; 
            white-space: nowrap; overflow: hidden; text-overflow: ellipsis; 
            max-width: 300px; display: block; cursor: pointer;
        }
        .item-url:hover { color: #ddd; text-decoration: underline; }

        .btn-group { margin-top: 8px; display: flex; gap: 8px; }
        .action-btn {
            padding: 4px 10px;
            border: none;
            border-radius: 4px;
            font-size: 11px;
            cursor: pointer;
            transition: opacity 0.2s;
            color: white;
        }
        .action-btn:hover { opacity: 0.8; }
        .btn-dash { background: #007bff; }
        .btn-srt { background: #00d084; }
        .btn-dl { background: #ff9800; color: black; }

        .panel-footer {
            padding: 10px;
            border-top: 1px solid rgba(255,255,255,0.1);
            text-align: right;
            font-size: 12px;
            color: #666;
        }
    `;

    // --- UI 构建 ---
    function initUI() {
        // 注入样式
        const styleEl = document.createElement('style');
        styleEl.textContent = styles;
        document.head.appendChild(styleEl);

        // 触发器（小球）
        const trigger = document.createElement('div');
        trigger.id = 'iqy-dash-trigger';
        trigger.innerHTML = 'Dash<br>0';
        trigger.onclick = () => togglePanel(true);
        document.body.appendChild(trigger);

        // 主面板
        const panel = document.createElement('div');
        panel.id = 'iqy-dash-panel';
        panel.innerHTML = `
            <div class="panel-header">
                <span class="panel-title">Dash & 字幕捕获助手</span>
                <span class="panel-close">&times;</span>
            </div>
            <div class="panel-content" id="dash-list-content">
                <div style="text-align:center; color:#555; padding: 20px;">等待捕获 Dash 链接...</div>
            </div>
            <div class="panel-footer">
                检测到请求自动加载，无字幕项将标记为红色
            </div>
        `;
        document.body.appendChild(panel);

        // 关闭事件
        panel.querySelector('.panel-close').onclick = () => togglePanel(false);
        
        // 点击面板外不关闭，避免操作不便，只通过点击 X 或 触发器切换
    }

    function togglePanel(show) {
        const panel = document.getElementById('iqy-dash-panel');
        if (show) {
            panel.style.display = 'flex'; // 先 display flex
            // 延时一小会儿加 show class 以触发 transition
            setTimeout(() => panel.classList.add('show'), 10);
        } else {
            panel.classList.remove('show');
            setTimeout(() => panel.style.display = 'none', 300); // 等动画结束
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

    // 2. 处理捕获的 URL
    function handleCapturedUrl(url) {
        // 去重
        if (state.captured.has(url)) return;
        state.captured.add(url);

        // 更新触发器计数
        const trigger = document.getElementById('iqy-dash-trigger');
        if(trigger) trigger.innerHTML = `Dash<br>${state.captured.size}`;

        // 创建数据对象
        const itemData = {
            id: Date.now() + Math.random(),
            dashUrl: url,
            hasSub: false,
            srtUrl: null,
            status: 'checking' // checking, found, none, error
        };
        state.items.push(itemData);

        // 立即渲染（显示正在检测）
        renderList();

        // 3. 预加载并分析
        analyzeDashContent(itemData);
    }

    // 3. 分析 Dash 响应内容
    function analyzeDashContent(item) {
        fetch(item.dashUrl)
            .then(res => res.json())
            .then(json => {
                try {
                    // 核心解析逻辑
                    const data = json.data;
                    const program = data.program;
                    
                    // 检查是否有字幕字段 (stl)
                    if (program && program.stl && program.stl.length > 0) {
                        // 获取基础域名
                        let dstl = data.dstl; 
                        if (!dstl.endsWith('/')) dstl += ''; // 确保拼接正确，有时 dstl 自带反斜杠，有时没有，这里假设 API 返回的标准
                        
                        // 获取第一个字幕对象的 SRT 路径
                        // 通常 stl 是个数组，可能有多种语言，这里默认取第一个或 main=1 的
                        const subObj = program.stl[0]; 
                        const srtPath = subObj.srt;
                        
                        if (srtPath) {
                            item.hasSub = true;
                            item.srtUrl = dstl + srtPath; // 拼接完整链接
                            item.status = 'found';
                        } else {
                            item.status = 'none';
                        }
                    } else {
                        item.status = 'none';
                    }
                } catch (e) {
                    console.error('解析出错', e);
                    item.status = 'error';
                }
                // 更新 UI
                updateItemUI(item);
            })
            .catch(err => {
                console.error('Fetch出错', err);
                item.status = 'error';
                updateItemUI(item);
            });
    }

    // 4. 渲染列表 (全量重新渲染太重，这里做简化，实际建议用 Virtual DOM 或增量更新)
    // 为了简单，这里清空重绘，因为 Dash 链接通常不会太多 (3-5个)
    function renderList() {
        const container = document.getElementById('dash-list-content');
        if (!container) return;
        container.innerHTML = '';

        // 倒序显示，新的在上面
        [...state.items].reverse().forEach(item => {
            const el = document.createElement('div');
            let statusClass = '';
            let statusText = '检测中...';

            if (item.status === 'found') {
                statusClass = 'has-sub';
                statusText = '✅ 包含字幕';
            } else if (item.status === 'none') {
                statusClass = 'no-sub';
                statusText = '无字幕';
            } else if (item.status === 'error') {
                statusClass = 'no-sub';
                statusText = '解析失败';
            } else {
                statusClass = ''; // checking
            }

            el.className = `log-item ${statusClass}`;
            el.innerHTML = `
                <div class="item-row">
                    <span class="item-status ${item.status === 'found' ? 'success' : ''}">${statusText}</span>
                    <span style="font-size:10px; color:#666;">${new Date(item.id).toLocaleTimeString()}</span>
                </div>
                <div class="item-url" title="${item.dashUrl}">Dash: ${item.dashUrl}</div>
                ${item.status === 'found' ? `
                    <div class="item-url" style="color:#00d084; margin-top:4px;" title="${item.srtUrl}">SRT: ${item.srtUrl}</div>
                ` : ''}
                <div class="btn-group">
                    <button class="action-btn btn-dash" data-url="${item.dashUrl}">复制 Dash</button>
                    ${item.status === 'found' ? `
                        <button class="action-btn btn-srt" data-srt="${item.srtUrl}">复制 SRT链接</button>
                        <button class="action-btn btn-dl" data-dl="${item.srtUrl}">下载 SRT</button>
                    ` : ''}
                </div>
            `;
            
            // 绑定事件委托太麻烦，直接闭包绑定
            const btnDash = el.querySelector('.btn-dash');
            btnDash.onclick = () => copyText(item.dashUrl);

            const btnSrt = el.querySelector('.btn-srt');
            if (btnSrt) btnSrt.onclick = () => copyText(item.srtUrl);

            const btnDl = el.querySelector('.btn-dl');
            if (btnDl) btnDl.onclick = () => downloadFile(item.srtUrl);

            container.appendChild(el);
        });
    }

    // 局部更新 UI (当异步请求回来时调用)
    function updateItemUI(item) {
        // 简单粗暴：直接重新渲染列表，保证顺序和状态正确
        renderList();
    }

    // --- 工具函数 ---
    function copyText(text) {
        if (typeof GM_setClipboard === 'function') {
            GM_setClipboard(text);
            showToast("复制成功！");
        } else {
            navigator.clipboard.writeText(text).then(() => showToast("复制成功！"));
        }
    }

    function downloadFile(url) {
        if (typeof GM_download === 'function') {
            GM_download({
                url: url,
                name: 'subtitle.srt',
                saveAs: true
            });
        } else {
            // 降级方案
            const a = document.createElement('a');
            a.href = url;
            a.download = 'subtitle.srt';
            a.target = '_blank';
            a.click();
        }
    }

    function showToast(msg) {
        // 简单的提示框
        const div = document.createElement('div');
        div.style.cssText = `position:fixed; top:50%; left:50%; transform:translate(-50%, -50%); background:rgba(0,0,0,0.8); color:white; padding:10px 20px; border-radius:5px; z-index:100000; font-size:14px; pointer-events:none;`;
        div.innerText = msg;
        document.body.appendChild(div);
        setTimeout(() => div.remove(), 1500);
    }

    // --- 初始化 ---
    window.addEventListener('load', () => {
        initUI();
        monitorNetwork();
    });

})();
