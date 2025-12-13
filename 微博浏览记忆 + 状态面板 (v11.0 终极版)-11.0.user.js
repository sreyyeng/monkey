// ==UserScript==
// @name         微博浏览记忆 + 状态面板 (v11.0 终极版)
// @namespace    http://tampermonkey.net/
// @version      11.0
// @description  将保存按钮改为实时状态面板，支持右键跳转，左键保存，修复多框问题，适配SPA
// @author       You
// @match        https://weibo.com/mygroups?*
// @match        https://weibo.com/u/*
// @match        https://weibo.com/hot/*
// @grant        GM_addStyle
// @run-at       document-idle
// ==/UserScript==

(function () {
    'use strict';

    // --- 核心配置 ---
    const CONFIG = {
        reminderInterval: 60 * 60 * 1000, // 1小时提醒
        highlightAutoFade: 10000, // 10秒后淡化高亮
        cleanupInterval: 3000, // 3秒检查一次多余高亮
        selector: {
            // 微博的时间标签选择器，尽量覆盖不同页面
            time: 'header [class*="head-info_time"][title], .woo-box-item-flex [class*="head-info_time"][title]',
            item: '.wbpro-scroller-item'
        }
    };

    // --- 全局状态 ---
    let isSearching = false;
    let lastHighlightElement = null;
    let lastUrl = location.href;
    let highlightFadeTimer = null;

    // --- CSS 样式 ---
    const css = `
        /* 1. 状态面板 (替代原按钮) */
        #wb-status-panel {
            position: fixed;
            top: 20%;
            right: 10px;
            width: 140px;
            background: rgba(255, 255, 255, 0.95);
            border-left: 5px solid #ff8200;
            box-shadow: 0 4px 15px rgba(0,0,0,0.15);
            border-radius: 4px;
            padding: 10px;
            z-index: 9999;
            font-size: 12px;
            color: #333;
            transition: all 0.3s ease;
            cursor: pointer;
            backdrop-filter: blur(5px);
            user-select: none;
        }
        #wb-status-panel:hover {
            transform: translateX(-5px);
            box-shadow: 0 6px 20px rgba(0,0,0,0.2);
        }
        #wb-status-panel .wb-title {
            font-weight: bold;
            color: #ff8200;
            margin-bottom: 4px;
            font-size: 13px;
        }
        #wb-status-panel .wb-time {
            font-family: 'Consolas', monospace;
            font-size: 16px;
            font-weight: bold;
            color: #333;
        }
        #wb-status-panel .wb-desc {
            font-size: 10px;
            color: #999;
            margin-top: 5px;
        }
        /* 保存成功的动画 */
        #wb-status-panel.saved {
            border-left-color: #4caf50;
            background: #e8f5e9;
        }
        #wb-status-panel.saved .wb-title { color: #4caf50; }

        /* 2. 高亮框 (保留但简化) */
        .wb-memory-target {
            border: 2px solid #ff4444 !important;
            background-color: rgba(255, 68, 68, 0.03) !important;
            transition: all 0.5s ease;
            box-sizing: border-box;
        }
        .wb-memory-target::after {
            content: '🚩 上次看到这里';
            position: absolute;
            top: -10px; right: 10px;
            background: #ff4444; color: #fff;
            font-size: 12px; padding: 2px 6px; border-radius: 4px;
            z-index: 10;
        }
        .wb-memory-target.fading {
            border-color: transparent !important;
            background-color: transparent !important;
        }
        .wb-memory-target.fading::after {
            opacity: 0;
            transition: opacity 2s;
        }

        /* 3. 清除按钮 (缩小并移动) */
        .wb-clear-btn {
            position: fixed;
            top: calc(20% + 90px);
            right: 10px;
            width: 30px; height: 30px;
            background: #eee; color: #666;
            border-radius: 50%; border: none;
            cursor: pointer; z-index: 9990;
            display: flex; align-items: center; justify-content: center;
            opacity: 0.6;
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

    // --- 核心功能：更新面板显示 ---
    function updatePanelDisplay() {
        const savedTime = localStorage.getItem('weiboLastTime');
        const displayEl = document.getElementById('wb-display-time');
        if (savedTime) {
            // 只显示时间部分 HH:mm，去掉日期如果太长
            const timePart = savedTime.includes(' ') ? savedTime.split(' ').pop().slice(0,5) : savedTime.slice(0,5);
            displayEl.innerText = timePart;
            panel.title = `完整时间: ${savedTime}`;
        } else {
            displayEl.innerText = "无记录";
        }
    }

    // --- 核心功能：保存位置 ---
    function performSave() {
        const centerY = window.scrollY + window.innerHeight / 2;
        const posts = document.querySelectorAll(CONFIG.selector.item);
        let closest = null;
        let minDis = Infinity;

        for (let post of posts) {
            const rect = post.getBoundingClientRect();
            // 优化：只检查在视口附近的元素
            if (rect.bottom < 0 || rect.top > window.innerHeight) continue;
            const dis = Math.abs(centerY - (rect.top + rect.height / 2 + window.scrollY));
            if (dis < minDis) { minDis = dis; closest = post; }
        }

        if (closest) {
            const timeEl = closest.querySelector(CONFIG.selector.time);
            if (timeEl) {
                const timeStr = timeEl.getAttribute('title');
                localStorage.setItem('weiboLastTime', timeStr);

                // 视觉反馈：UI 变绿
                panel.classList.add('saved');
                panel.querySelector('.wb-title').innerText = "已保存位置";
                updatePanelDisplay();

                // 视觉反馈：给帖子加个框 (即使你不需要高亮，稍微提示一下当前是哪条也好)
                setHighlight(closest, { autoFade: true, reason: '手动保存' });

                setTimeout(() => {
                    panel.classList.remove('saved');
                    panel.querySelector('.wb-title').innerText = "微博浏览记录";
                }, 1500);
            } else {
                showToast('❌ 当前位置找不到时间标签，请移动一下');
            }
        } else {
            showToast('❌ 未检测到微博内容');
        }
    }

    // --- 核心功能：执行搜索与跳转 ---
    function restorePosition() {
        const savedTimeStr = localStorage.getItem('weiboLastTime');
        if (!savedTimeStr) {
            showToast('⚠️ 还没有保存过位置');
            return;
        }

        showToast('🚀 开始搜索目标: ' + savedTimeStr);
        startSearch(savedTimeStr, () => {
             // 搜索结束回调
        });
    }

    // --- 辅助：高亮控制 ---
    function setHighlight(element, options = {}) {
        // 清除旧的
        document.querySelectorAll('.wb-memory-target').forEach(el => el.classList.remove('wb-memory-target', 'fading'));

        if (element) {
            element.classList.add('wb-memory-target');
            if (options.autoFade) {
                setTimeout(() => {
                    element.classList.add('fading');
                }, 2000); // 2秒后就开始淡化，不干扰视线
            }
        }
    }

    // --- 辅助：搜索逻辑 (保留你的优秀算法) ---
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
                // 兼容处理：有时候 title 格式不一样，简单清洗
                if (!itemTimeStr) continue;

                const itemTime = new Date(itemTimeStr);
                const item = timeEl.closest(CONFIG.selector.item);
                if (!item || isNaN(itemTime.getTime())) continue;

                const timeDiff = Math.abs(itemTime - targetDate);

                if (itemTimeStr === targetTimeStr) {
                    matches.push({ item, priority: 3, diff: 0 });
                } else if (timeDiff < 60000) { // 1分钟内都算匹配
                    matches.push({ item, priority: 2, diff: timeDiff });
                }

                if (itemTime < targetDate && (targetDate - itemTime) > 120000) {
                    foundOlder = true;
                    if (!firstOlderItem) firstOlderItem = item;
                }
            }

            if (matches.length > 0) {
                matches.sort((a, b) => b.priority - a.priority || a.diff - b.diff);
                const targetItem = matches[0].item; // 取最匹配的

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
            if (checkCount > 50) { // 约40秒超时
                clearInterval(checkInterval);
                isSearching = false;
                showToast('❌ 未找到目标位置');
                onComplete();
                return;
            }

            window.scrollTo(0, document.body.scrollHeight);
        }, 800);
    }

    // --- 辅助：简易提示 ---
    function showToast(msg) {
        const div = document.createElement('div');
        div.innerText = msg;
        div.style.cssText = 'position:fixed;top:15%;left:50%;transform:translateX(-50%);background:rgba(0,0,0,0.8);color:fff;padding:8px 15px;border-radius:4px;z-index:10000;font-size:14px;color:white;';
        document.body.appendChild(div);
        setTimeout(() => div.remove(), 2000);
    }

    // --- 事件监听 ---
    // 左键点击面板：保存
    panel.addEventListener('click', (e) => {
        e.preventDefault(); // 防止触发页面其他事件
        performSave();
    });

    // 右键点击面板：跳转 (阻止默认菜单)
    panel.addEventListener('contextmenu', (e) => {
        e.preventDefault();
        restorePosition();
    });

    clearBtn.addEventListener('click', () => {
         document.querySelectorAll('.wb-memory-target').forEach(el => el.classList.remove('wb-memory-target', 'fading'));
    });

    // --- 初始化 ---
    function init() {
        updatePanelDisplay();

        // 监听 URL 变化
        const observer = new MutationObserver(() => {
            if (location.href !== lastUrl) {
                lastUrl = location.href;
                // 页面跳转后重置
                setTimeout(updatePanelDisplay, 1000);
            }
        });
        observer.observe(document.body, { childList: true, subtree: true });

        // 定期清理多余高亮（不影响性能的前提下）
        setInterval(() => {
            const targets = document.querySelectorAll('.wb-memory-target');
            if (targets.length > 1) {
                targets.forEach((el, index) => {
                    if (index < targets.length - 1) el.classList.remove('wb-memory-target');
                });
            }
        }, 3000);

        // 简化时间显示 (可选，如果你觉得不需要可以注释掉)
        setInterval(() => {
             document.querySelectorAll(CONFIG.selector.time).forEach(el => {
                 if(!el.dataset.fixed && el.getAttribute('title')) {
                     el.innerText = el.getAttribute('title').slice(11, 16); // 只显示 HH:mm
                     el.dataset.fixed = 'true';
                 }
             });
        }, 2000);
    }

    window.addEventListener('load', init);

})();