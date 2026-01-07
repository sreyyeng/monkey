// ==UserScript==
// @name         微博浏览记忆 + 状态面板 (v11.1 修复版)
// @namespace    http://tampermonkey.net/
// @version      11.1
// @description  修复微博页面更新导致找不到时间标签的问题，适配新版混淆类名
// @author       You
// @match        https://weibo.com/mygroups?*
// @match        https://weibo.com/u/*
// @grant        GM_addStyle
// @run-at       document-idle
// ==/UserScript==

(function () {
    'use strict';

    // --- 核心配置 ---
    const CONFIG = {
        reminderInterval: 60 * 60 * 1000,
        highlightAutoFade: 10000,
        cleanupInterval: 3000,
        selector: {
            // [修复点] 修改时间选择器：
            // 1. 兼容旧版 'head-info_time'
            // 2. 适配新版 '_time_xxxx' (只要包含 "time" 的 class 且有 title 属性)
            time: 'a[class*="head-info_time"][title], a[class*="_time"][title], a[class*="time"][title]',
            item: '.wbpro-scroller-item'
        }
    };

    // --- 全局状态 ---
    let isSearching = false;
    let lastUrl = location.href;

    // --- CSS 样式 ---
    const css = `
        #wb-status-panel {
            position: fixed; top: 20%; right: 10px; width: 140px;
            background: rgba(255, 255, 255, 0.95);
            border-left: 5px solid #ff8200;
            box-shadow: 0 4px 15px rgba(0,0,0,0.15);
            border-radius: 4px; padding: 10px; z-index: 9999;
            font-size: 12px; color: #333; transition: all 0.3s ease;
            cursor: pointer; backdrop-filter: blur(5px); user-select: none;
        }
        #wb-status-panel:hover { transform: translateX(-5px); box-shadow: 0 6px 20px rgba(0,0,0,0.2); }
        #wb-status-panel .wb-title { font-weight: bold; color: #ff8200; margin-bottom: 4px; font-size: 13px; }
        #wb-status-panel .wb-time { font-family: 'Consolas', monospace; font-size: 16px; font-weight: bold; color: #333; }
        #wb-status-panel .wb-desc { font-size: 10px; color: #999; margin-top: 5px; }
        #wb-status-panel.saved { border-left-color: #4caf50; background: #e8f5e9; }
        #wb-status-panel.saved .wb-title { color: #4caf50; }

        .wb-memory-target {
            border: 2px solid #ff4444 !important;
            background-color: rgba(255, 68, 68, 0.03) !important;
            transition: all 0.5s ease; box-sizing: border-box;
        }
        .wb-memory-target::after {
            content: '🚩 上次看到这里'; position: absolute; top: -10px; right: 10px;
            background: #ff4444; color: #fff; font-size: 12px; padding: 2px 6px; border-radius: 4px; z-index: 10;
        }
        .wb-memory-target.fading { border-color: transparent !important; background-color: transparent !important; }
        .wb-memory-target.fading::after { opacity: 0; transition: opacity 2s; }

        .wb-clear-btn {
            position: fixed; top: calc(20% + 90px); right: 10px; width: 30px; height: 30px;
            background: #eee; color: #666; border-radius: 50%; border: none; cursor: pointer;
            z-index: 9990; display: flex; align-items: center; justify-content: center; opacity: 0.6;
        }
        .wb-clear-btn:hover { opacity: 1; background: #ddd; }
    `;
    const styleEl = document.createElement('style');
    styleEl.innerHTML = css;
    document.head.appendChild(styleEl);

    // --- UI 构建 ---
    const panel = document.createElement('div');
    panel.id = 'wb-status-panel';
    panel.innerHTML = `
        <div class="wb-title">微博浏览记录</div>
        <div class="wb-time" id="wb-display-time">--:--</div>
        <div class="wb-desc">左键保存 | 右键跳转</div>
    `;
    document.body.appendChild(panel);

    const clearBtn = document.createElement('button');
    clearBtn.className = 'wb-clear-btn';
    clearBtn.innerHTML = '×';
    clearBtn.title = "清除高亮";
    document.body.appendChild(clearBtn);

    // --- 核心功能 ---
    function updatePanelDisplay() {
        const savedTime = localStorage.getItem('weiboLastTime');
        const displayEl = document.getElementById('wb-display-time');
        if (savedTime) {
            // 安全截取时间
            const timeMatch = savedTime.match(/\d{2}:\d{2}/);
            const displayTime = timeMatch ? timeMatch[0] : savedTime.slice(-5);
            displayEl.innerText = displayTime;
            panel.title = `完整时间: ${savedTime}`;
        } else {
            displayEl.innerText = "无记录";
        }
    }

    function performSave() {
        const centerY = window.scrollY + window.innerHeight / 2;
        const posts = document.querySelectorAll(CONFIG.selector.item);
        let closest = null;
        let minDis = Infinity;

        for (let post of posts) {
            const rect = post.getBoundingClientRect();
            if (rect.bottom < 0 || rect.top > window.innerHeight) continue;
            const dis = Math.abs(centerY - (rect.top + rect.height / 2 + window.scrollY));
            if (dis < minDis) { minDis = dis; closest = post; }
        }

        if (closest) {
            // [关键] 在当前帖子内查找时间元素
            const timeEl = closest.querySelector(CONFIG.selector.time);
            if (timeEl) {
                const timeStr = timeEl.getAttribute('title');
                if(!timeStr) {
                    showToast('⚠️ 找到标签但无时间数据，请刷新重试');
                    return;
                }
                localStorage.setItem('weiboLastTime', timeStr);

                panel.classList.add('saved');
                panel.querySelector('.wb-title').innerText = "已保存位置";
                updatePanelDisplay();
                setHighlight(closest, { autoFade: true });

                setTimeout(() => {
                    panel.classList.remove('saved');
                    panel.querySelector('.wb-title').innerText = "微博浏览记录";
                }, 1500);
            } else {
                showToast('❌ 无法识别当前位置的时间（新版页面结构？）');
                console.log('Target post:', closest.innerHTML); // 调试用
            }
        } else {
            showToast('❌ 未检测到微博内容');
        }
    }

    function restorePosition() {
        const savedTimeStr = localStorage.getItem('weiboLastTime');
        if (!savedTimeStr) { showToast('⚠️ 还没有保存过位置'); return; }
        showToast('🚀 开始搜索目标: ' + savedTimeStr);
        startSearch(savedTimeStr, () => {});
    }

    function setHighlight(element, options = {}) {
        document.querySelectorAll('.wb-memory-target').forEach(el => el.classList.remove('wb-memory-target', 'fading'));
        if (element) {
            element.classList.add('wb-memory-target');
            if (options.autoFade) setTimeout(() => element.classList.add('fading'), 2000);
        }
    }

    function startSearch(targetTimeStr, onComplete) {
        if (isSearching) return;
        isSearching = true;
        let checkCount = 0;
        const targetDate = new Date(targetTimeStr);

        const checkInterval = setInterval(() => {
            const timeElements = Array.from(document.querySelectorAll(CONFIG.selector.time));
            let matches = [];
            let foundOlder = false;
            let firstOlderItem = null;

            for (const timeEl of timeElements) {
                const itemTimeStr = timeEl.getAttribute('title');
                if (!itemTimeStr) continue;

                const itemTime = new Date(itemTimeStr);
                const item = timeEl.closest(CONFIG.selector.item);
                if (!item || isNaN(itemTime.getTime())) continue;

                const timeDiff = Math.abs(itemTime - targetDate);

                if (itemTimeStr === targetTimeStr) {
                    matches.push({ item, priority: 3, diff: 0 });
                } else if (timeDiff < 60000) {
                    matches.push({ item, priority: 2, diff: timeDiff });
                }

                if (itemTime < targetDate && (targetDate - itemTime) > 120000) {
                    foundOlder = true;
                    if (!firstOlderItem) firstOlderItem = item;
                }
            }

            if (matches.length > 0) {
                matches.sort((a, b) => b.priority - a.priority || a.diff - b.diff);
                const targetItem = matches[0].item;
                targetItem.scrollIntoView({ behavior: 'smooth', block: 'center' });
                setHighlight(targetItem, { autoFade: false });
                showToast('✅ 已定位到上次位置');
                clearInterval(checkInterval);
                isSearching = false;
                onComplete();
                return;
            }

            if (foundOlder && firstOlderItem) {
                firstOlderItem.scrollIntoView({ behavior: 'smooth', block: 'center' });
                setHighlight(firstOlderItem, { autoFade: false });
                showToast('⚠️ 原微博可能已消失，跳转至临近时间');
                clearInterval(checkInterval);
                isSearching = false;
                onComplete();
                return;
            }

            checkCount++;
            if (checkCount > 50) {
                clearInterval(checkInterval);
                isSearching = false;
                showToast('❌ 未找到目标位置');
                onComplete();
                return;
            }

            window.scrollTo(0, document.body.scrollHeight);
        }, 800);
    }

    function showToast(msg) {
        const div = document.createElement('div');
        div.innerText = msg;
        div.style.cssText = 'position:fixed;top:15%;left:50%;transform:translateX(-50%);background:rgba(0,0,0,0.8);color:fff;padding:8px 15px;border-radius:4px;z-index:10000;font-size:14px;color:white;';
        document.body.appendChild(div);
        setTimeout(() => div.remove(), 2000);
    }

    panel.addEventListener('click', (e) => { e.preventDefault(); performSave(); });
    panel.addEventListener('contextmenu', (e) => { e.preventDefault(); restorePosition(); });
    clearBtn.addEventListener('click', () => document.querySelectorAll('.wb-memory-target').forEach(el => el.classList.remove('wb-memory-target', 'fading')));

    function init() {
        updatePanelDisplay();
        const observer = new MutationObserver(() => {
            if (location.href !== lastUrl) {
                lastUrl = location.href;
                setTimeout(updatePanelDisplay, 1000);
            }
        });
        observer.observe(document.body, { childList: true, subtree: true });

        // 简化时间显示 (可选)
        setInterval(() => {
             document.querySelectorAll(CONFIG.selector.time).forEach(el => {
                 if(!el.dataset.fixed && el.getAttribute('title')) {
                     // 简单正则提取时间，防止格式变动导致报错
                     const match = el.getAttribute('title').match(/\d{2}:\d{2}/);
                     if(match) el.innerText = match[0];
                     el.dataset.fixed = 'true';
                 }
             });
        }, 2000);
    }

    window.addEventListener('load', init);

})();
