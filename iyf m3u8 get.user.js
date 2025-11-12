// ==UserScript==
// @name         iyf m3u8 get
// @namespace    http://tampermonkey.net/
// @version      3.3
// @description  【彻底修复】面板立即显示无需刷新，滚动条左侧显示，固定列表高度
// @author       Gemini & YourName
// @match        *://*.iyf.tv/play/*
// @match        *://*.iyf.tv/detail/*
// @downloadURL  https://github.com/sreyyeng/monkey/raw/refs/heads/main/iyf%20m3u8%20get.user.js
// @updateURL    https://github.com/sreyyeng/monkey/raw/refs/heads/main/iyf%20m3u8%20get.user.js
// @icon         https://www.google.com/s2/favicons?sz=64&domain=iyf.tv
// @grant        GM_addStyle
// @grant        GM_setClipboard
// @grant        unsafeWindow
// @license      MIT
// @run-at       document-start
// ==/UserScript==

(function() {
    'use strict';

    // --- 1. SVG 图标定义 ---
    const ICONS = {
        toggleRight: `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" fill="currentColor" viewBox="0 0 16 16"><path fill-rule="evenodd" d="M11.354 1.646a.5.5 0 0 1 0 .708L5.707 8l5.647 5.646a.5.5 0 0 1-.708.708l-6-6a.5.5 0 0 1 0-.708l6-6a.5.5 0 0 1 .708 0z"/></svg>`,
        toggleLeft: `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" fill="currentColor" viewBox="0 0 16 16"><path fill-rule="evenodd" d="M4.646 1.646a.5.5 0 0 1 .708 0l6 6a.5.5 0 0 1 0 .708l-6 6a.5.5 0 0 1-.708-.708L10.293 8 4.646 2.354a.5.5 0 0 1 0-.708z"/></svg>`,
        trash: `<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" fill="currentColor" viewBox="0 0 16 16"><path d="M5.5 5.5A.5.5 0 0 1 6 6v6a.5.5 0 0 1-1 0V6a.5.5 0 0 1 .5-.5zm2.5 0a.5.5 0 0 1 .5.5v6a.5.5 0 0 1-1 0V6a.5.5 0 0 1 .5-.5zm3 .5a.5.5 0 0 0-1 0v6a.5.5 0 0 0 1 0V6z"/><path fill-rule="evenodd" d="M14.5 3a1 1 0 0 1-1 1H13v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V4h-.5a1 1 0 0 1-1-1V2a1 1 0 0 1 1-1H6a1 1 0 0 1 1-1h2a1 1 0 0 1 1 1h3.5a1 1 0 0 1 1 1v1zM4.118 4 4 4.059V13a1 1 0 0 0 1 1h6a1 1 0 0 0 1-1V4.059L11.882 4H4.118zM2.5 3V2h11v1h-11z"/></svg>`
    };

    // --- 2. 样式定义 ---
    GM_addStyle(`
        :root {
            --bg-primary: #1e1e2e; --bg-secondary: #27293d; --bg-tertiary: #363a59;
            --text-primary: #cad3f5; --text-secondary: #a5adce;
            --accent-blue: #89b4fa; --accent-green: #a6e3a1; --accent-red: #f38ba8; --accent-mauve: #cba6f7;
            --border-color: #494d64;
        }
        #iyf-helper-panel {
            position: fixed; top: 120px; right: 0; width: 320px; 
            max-height: 700px;
            background-color: var(--bg-primary); color: var(--text-primary);
            border: 1px solid var(--border-color);
            border-top-left-radius: 12px; border-bottom-left-radius: 12px;
            z-index: 99999; display: flex; flex-direction: column;
            font-family: 'Segoe UI', 'Roboto', 'Helvetica Neue', 'Arial', sans-serif;
            box-shadow: -6px 6px 20px rgba(0,0,0,0.4);
            transition: transform 0.4s cubic-bezier(0.25, 1, 0.5, 1);
            transform: translateX(0);
        }
        #iyf-helper-panel.collapsed { transform: translateX(321px); }
        #iyf-helper-header {
            padding: 12px 15px; background-color: rgba(0,0,0,0.2); font-weight: bold;
            cursor: default; text-align: center; border-bottom: 1px solid var(--border-color);
            border-top-left-radius: 12px; font-size: 16px; color: var(--accent-mauve);
        }
        #iyf-helper-title {
            font-size: 14px; padding: 10px 15px; background-color: var(--bg-secondary);
            white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
            border-bottom: 1px solid var(--border-color);
        }
        
        /* 集数列表 - 固定高度，滚动条在左侧 */
        #iyf-episode-list { 
            list-style: none; padding: 10px; margin: 0; 
            overflow-y: auto; overflow-x: hidden;
            max-height: 400px;
            min-height: 150px;
            direction: rtl;
            scrollbar-width: thin;
            scrollbar-color: var(--accent-blue) var(--bg-secondary);
        }
        
        #iyf-episode-list::-webkit-scrollbar { width: 12px; }
        #iyf-episode-list::-webkit-scrollbar-track { 
            background: var(--bg-secondary);
            border-radius: 6px;
            margin: 4px 0;
        }
        #iyf-episode-list::-webkit-scrollbar-thumb { 
            background: var(--accent-blue);
            border-radius: 6px;
            border: 2px solid var(--bg-secondary);
            min-height: 40px;
        }
        #iyf-episode-list::-webkit-scrollbar-thumb:hover { 
            background: #a6d1ff;
            border-color: var(--bg-tertiary);
        }
        #iyf-episode-list::-webkit-scrollbar-thumb:active {
            background: var(--accent-mauve);
        }

        .episode-item {
            direction: ltr;
            padding: 10px 12px; margin-bottom: 6px; border-radius: 6px;
            cursor: pointer; transition: all 0.2s ease-out;
            font-size: 14px; border-left: 4px solid var(--bg-tertiary);
            display: flex; justify-content: space-between; align-items: center;
        }
        .episode-item:hover { background-color: var(--bg-tertiary); }
        .episode-item.status-red { border-left-color: var(--accent-red); }
        .episode-item.status-green { border-left-color: var(--accent-green); color: var(--accent-green); }
        .episode-item.active { background-color: var(--bg-tertiary); font-weight: bold; }

        .delete-button {
            background: none; border: none; color: var(--text-secondary); cursor: pointer;
            padding: 5px; border-radius: 50%; display: flex; align-items: center; justify-content: center;
            opacity: 0; visibility: hidden; transition: all 0.2s ease; transform: scale(0.8);
        }
        #iyf-episode-list .episode-item.status-green .delete-button {
            opacity: 0.7; visibility: visible; transform: scale(1);
        }
        .delete-button:hover { background-color: var(--accent-red); color: white; opacity: 1; }

        #iyf-command-area { padding: 10px; border-top: 1px solid var(--border-color); }
        #iyf-command-area textarea {
            width: 100%; height: 100px; box-sizing: border-box; background-color: var(--bg-secondary); color: var(--text-primary);
            border: 1px solid var(--border-color); border-radius: 6px; font-size: 12px; resize: vertical; padding: 8px;
        }
        #iyf-copy-button {
            width: 100%; padding: 10px; margin-top: 8px; background-color: var(--accent-blue); color: var(--bg-primary); border: none;
            border-radius: 6px; cursor: pointer; font-weight: bold; font-size: 14px; transition: background-color 0.2s;
        }
        #iyf-copy-button:hover { background-color: #a6d1ff; }
        #iyf-toggle-button {
            position: absolute; top: 0px; left: -32px; width: 32px; height: 50px;
            background-color: var(--bg-primary); border: 1px solid var(--border-color); border-right: none;
            border-top-left-radius: 8px; border-bottom-left-radius: 8px;
            cursor: pointer; display: flex; align-items: center; justify-content: center;
            color: var(--text-primary); font-size: 20px;
        }
        
        /* 加载状态 */
        .loading-hint {
            direction: ltr;
            padding: 20px;
            text-align: center;
            color: var(--text-secondary);
            font-size: 13px;
        }
    `);

    // --- 3. 全局变量 ---
    let panel = null;
    let videoTitle = '', videoId = '', episodes = [], requestNonce = 0, pendingEpisodeId = null;
    let isM3U8InterceptionSetup = false;
    let contentLoadAttempts = 0;
    const MAX_CONTENT_LOAD_ATTEMPTS = 50; // 最多尝试50次

    // --- 4. 立即创建并显示面板（空的也没关系）---
    function createAndShowPanel() {
        if (panel && document.body.contains(panel)) {
            console.log('[iyf助手] 面板已存在');
            return;
        }
        
        // 等待body存在
        if (!document.body) {
            setTimeout(createAndShowPanel, 50);
            return;
        }
        
        panel = document.createElement('div');
        panel.id = 'iyf-helper-panel';
        panel.innerHTML = `
            <div id="iyf-toggle-button">${ICONS.toggleRight}</div>
            <div id="iyf-helper-header">iyf M3U8 助手 v3.3</div>
            <div id="iyf-helper-title">正在加载影片信息...</div>
            <ul id="iyf-episode-list">
                <div class="loading-hint">⏳ 等待页面内容加载...</div>
            </ul>
            <div id="iyf-command-area">
                <textarea id="iyf-command-output" readonly placeholder="捕获到的下载命令将显示在此处..."></textarea>
                <button id="iyf-copy-button">复制全部命令</button>
            </div>
        `;
        
        // 绑定按钮事件
        panel.querySelector('#iyf-copy-button').addEventListener('click', () => {
            const textToCopy = document.getElementById('iyf-command-output').value;
            if (textToCopy) { 
                GM_setClipboard(textToCopy, 'text'); 
                alert('所有命令已复制到剪贴板！'); 
            } else { 
                alert('没有可复制的命令。'); 
            }
        });
        
        panel.querySelector('#iyf-toggle-button').addEventListener('click', () => {
            panel.classList.toggle('collapsed');
            const button = panel.querySelector('#iyf-toggle-button');
            button.innerHTML = panel.classList.contains('collapsed') ? ICONS.toggleLeft : ICONS.toggleRight;
        });
        
        document.body.appendChild(panel);
        console.log('[iyf助手] ✅ 面板已创建并显示');
    }

    // --- 5. M3U8 拦截 ---
    function setupM3U8Interception() {
        if (isM3U8InterceptionSetup) return;
        isM3U8InterceptionSetup = true;
        
        function handleM3U8Found(m3u8Url, capturedNonce, capturedEpisodeId) {
            if (capturedNonce !== requestNonce || !capturedEpisodeId) return;
            const episode = episodes.find(ep => ep.href && ep.href.includes(`id=${capturedEpisodeId}`));
            if (episode && !episode.m3u8) {
                console.log(`[iyf助手] 精准关联 M3U8 -> ${episode.title} (ID: ${capturedEpisodeId})`);
                episode.m3u8 = m3u8Url;
                pendingEpisodeId = null;
                updateEpisodeUI(episode);
                updateCommandsDisplay();
            }
        }
        
        const originalFetch = unsafeWindow.fetch;
        unsafeWindow.fetch = function(...args) {
            const url = args[0] instanceof Request ? args[0].url : args[0];
            if (typeof url === 'string' && url.includes('.m3u8')) {
                const capturedNonce = requestNonce, capturedEpisodeId = pendingEpisodeId;
                Promise.resolve().then(() => handleM3U8Found(url, capturedNonce, capturedEpisodeId));
            }
            return originalFetch.apply(this, args);
        };
        
        const originalXhrOpen = unsafeWindow.XMLHttpRequest.prototype.open;
        unsafeWindow.XMLHttpRequest.prototype.open = function(method, url, ...rest) {
            if (typeof url === 'string' && url.includes('.m3u8')) {
                const capturedNonce = requestNonce, capturedEpisodeId = pendingEpisodeId;
                this.addEventListener('load', () => {
                     Promise.resolve().then(() => handleM3U8Found(this.responseURL || url, capturedNonce, capturedEpisodeId));
                });
            }
            return originalXhrOpen.apply(this, [method, url, ...rest]);
        };
        
        console.log('[iyf助手] M3U8拦截已启动');
    }

    // --- 6. UI更新函数 ---
    function updateEpisodeUI(episode) {
        if (!episode || !episode.element) return;
        const el = episode.element;
        if (episode.m3u8) {
            el.classList.add('status-green');
            el.classList.remove('status-red');
            el.title = `M3U8已捕获: ${episode.m3u8}`;
        } else {
            el.classList.add('status-red');
            el.classList.remove('status-green');
            el.title = '点击播放以捕获链接';
        }
    }

    function updateCommandsDisplay() {
        const capturedCommands = episodes.filter(ep => ep.m3u8).map(ep => `"${ep.m3u8}" --saveName "${videoTitle}_${ep.title}" --enableDelAfterDone`);
        const outputEl = document.getElementById('iyf-command-output');
        if (outputEl) {
            outputEl.value = capturedCommands.join('\n');
        }
    }

    function updateActiveEpisodeIndicator() {
        const currentId = new URLSearchParams(window.location.search).get('id');
        episodes.forEach(ep => {
            if (ep.element) {
                ep.element.classList.toggle('active', ep.href && ep.href.includes(currentId));
            }
        });
    }

    // --- 7. 尝试加载内容 ---
    function tryLoadContent() {
        contentLoadAttempts++;
        
        if (contentLoadAttempts > MAX_CONTENT_LOAD_ATTEMPTS) {
            console.log('[iyf助手] ⚠️ 达到最大尝试次数，停止加载');
            const listEl = document.getElementById('iyf-episode-list');
            if (listEl && listEl.querySelector('.loading-hint')) {
                listEl.innerHTML = '<div class="loading-hint">❌ 未找到影片信息<br>请确认页面已正确加载</div>';
            }
            return;
        }
        
        console.log(`[iyf助手] 尝试加载内容 (${contentLoadAttempts}/${MAX_CONTENT_LOAD_ATTEMPTS})...`);
        
        const pathParts = window.location.pathname.split('/');
        const newVideoId = pathParts[2];
        
        if (!newVideoId) {
            console.log('[iyf助手] 未找到视频ID，继续等待...');
            setTimeout(tryLoadContent, 200);
            return;
        }
        
        const currentUrlId = new URLSearchParams(window.location.search).get('id');
        if (newVideoId !== videoId) {
            videoId = newVideoId; 
            episodes = []; 
            videoTitle = ''; 
            requestNonce++;
            pendingEpisodeId = currentUrlId;
        }
        
        const titleElement = document.querySelector('h4.d-inline.h4');
        const episodeListContainer = document.querySelector('div.n-media-list');
        
        if (!titleElement || !episodeListContainer) {
            console.log('[iyf助手] 页面元素未就绪，继续等待...');
            setTimeout(tryLoadContent, 200);
            return;
        }
        
        const episodeLinks = episodeListContainer.querySelectorAll('a.media-button');
        if (episodeLinks.length === 0) {
            console.log('[iyf助手] 未找到剧集链接，继续等待...');
            setTimeout(tryLoadContent, 200);
            return;
        }
        
        // 找到了！开始填充内容
        videoTitle = titleElement.innerText.trim();
        const titleEl = document.getElementById('iyf-helper-title');
        if (titleEl) {
            titleEl.innerText = `影片: ${videoTitle}`;
        }
        
        episodes = Array.from(episodeLinks).map(link => ({
            title: link.getAttribute('title')?.trim() || link.innerText.trim(), 
            href: link.getAttribute('href'),
            originalLink: link, 
            m3u8: null, 
            element: null
        })).reverse();
        
        renderEpisodeList();
        updateActiveEpisodeIndicator();
        updateCommandsDisplay();
        
        console.log(`[iyf助手] ✅ 内容加载成功！找到 ${episodes.length} 集`);
    }

    function renderEpisodeList() {
        const listContainer = document.getElementById('iyf-episode-list');
        if (!listContainer) return;
        
        listContainer.innerHTML = '';
        episodes.forEach(episode => {
            const item = document.createElement('li');
            item.className = 'episode-item';
            
            const deleteButton = document.createElement('button');
            deleteButton.className = 'delete-button';
            deleteButton.innerHTML = ICONS.trash;
            deleteButton.title = '删除此条链接';
            deleteButton.addEventListener('click', (event) => {
                event.stopPropagation();
                console.log(`[iyf助手] 用户删除剧集链接: ${episode.title}`);
                episode.m3u8 = null;
                updateEpisodeUI(episode);
                updateCommandsDisplay();
            });
            
            const titleSpan = document.createElement('span');
            titleSpan.innerText = `第 ${episode.title} 集`;
            item.appendChild(titleSpan);
            item.appendChild(deleteButton);
            
            item.addEventListener('click', () => {
                if (episode.originalLink && !item.classList.contains('active')) {
                    requestNonce++;
                    try {
                        const url = new URL(episode.href, window.location.origin);
                        pendingEpisodeId = url.searchParams.get('id');
                    } catch (e) {
                        const match = episode.href.match(/id=([^&]+)/);
                        pendingEpisodeId = match ? match[1] : null;
                    }
                    console.log(`[iyf助手] 用户点击新剧集，令牌: ${requestNonce}, ID: ${pendingEpisodeId}`);
                    episode.originalLink.click();
                }
            });
            
            episode.element = item;
            updateEpisodeUI(episode);
            listContainer.appendChild(item);
        });
    }

    // --- 8. URL变化监听 ---
    function setupURLChangeListener() {
        let lastUrl = location.href;
        new MutationObserver(() => {
            const url = location.href;
            if (url !== lastUrl) {
                lastUrl = url;
                pendingEpisodeId = new URLSearchParams(window.location.search).get('id');
                console.log('[iyf助手] URL变化，重新加载内容');
                
                // 重置状态
                contentLoadAttempts = 0;
                const titleEl = document.getElementById('iyf-helper-title');
                if (titleEl) titleEl.innerText = '正在加载影片信息...';
                const listEl = document.getElementById('iyf-episode-list');
                if (listEl) listEl.innerHTML = '<div class="loading-hint">⏳ 等待页面内容加载...</div>';
                
                setTimeout(tryLoadContent, 300);
            }
        }).observe(document, {subtree: true, childList: true});
    }

    // --- 9. 启动脚本 ---
    console.log('[iyf助手] 🚀 脚本启动...');
    
    // 第1步：立即设置M3U8拦截（越早越好）
    setupM3U8Interception();
    requestNonce++;
    
    // 第2步：立即创建并显示空面板（不等内容）
    createAndShowPanel();
    
    // 第3步：开始尝试加载内容
    setTimeout(tryLoadContent, 100);
    
    // 第4步：设置URL变化监听
    setupURLChangeListener();
    
    console.log('[iyf助手] ✅ 启动完成，面板应该已经显示');

})();
