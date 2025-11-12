// ==UserScript==
// @name         爱奇艺 Dash 链接捕获
// @namespace    http://tampermonkey.net/
// @version      4.0
// @description  自动监听并捕获爱奇艺 dash 请求地址，并提供一键复制所有链接的功能。
// @author       YourName
// @match        *://www.iqiyi.com/*
// @grant        none
// @license      MIT
// ==/UserScript==

(function() {
    'use strict';

    // 用于存储捕获到的所有 dash 链接，Set 可以自动去重
    let capturedUrls = new Set();

    /**
     * 创建并显示操作面板
     */
    function createPanel() {
        let panel = document.createElement("div");
        panel.id = "dashCapturePanel";
        panel.style.position = "fixed";
        panel.style.top = "80px";
        panel.style.left = "10px";
        panel.style.width = "340px";
        panel.style.maxHeight = "400px";
        panel.style.backgroundColor = "rgba(0, 0, 0, 0.85)";
        panel.style.color = "white";
        panel.style.fontSize = "14px";
        panel.style.padding = "10px";
        panel.style.borderRadius = "8px";
        panel.style.zIndex = "99999";
        panel.style.fontFamily = "Arial, sans-serif";
        panel.style.boxShadow = "0 2px 10px rgba(0,0,0,0.5)";
        panel.innerHTML = `
            <b style="font-size: 16px;">爱奇艺 Dash 链接捕获</b>
            <hr style="border-color: #444;">
            <div id='logContent' style="max-height: 250px; overflow-y: auto; padding-right: 5px; border-bottom: 1px solid #444; margin-bottom: 10px;"></div>
            <div style="display: flex; justify-content: space-between; align-items: center;">
                <span id="dashCount">已捕获 0 个链接</span>
                <button id="copyDashLinks" style="padding: 6px 12px; border: none; background: #007bff; color: white; border-radius: 5px; cursor: pointer; font-size: 14px;">复制全部</button>
            </div>
        `;

        document.body.appendChild(panel);

        // 为“复制全部”按钮绑定点击事件
        document.getElementById("copyDashLinks").addEventListener("click", () => {
            if (capturedUrls.size === 0) {
                alert("尚未捕获到任何 dash 链接！");
                return;
            }
            // 将 Set 转换为数组，并用换行符连接成一个字符串
            let textToCopy = Array.from(capturedUrls).join("\n");
            // 使用现代的 navigator.clipboard API 写入剪贴板
            navigator.clipboard.writeText(textToCopy).then(() => {
                alert(`成功复制 ${capturedUrls.size} 个 dash 链接！`);
            }).catch(err => {
                console.error("复制失败:", err);
                alert("复制失败，请检查浏览器权限或手动复制。");
            });
        });
    }

    /**
     * 向面板的日志区域添加新消息
     * @param {string} message - 要显示的消息
     */
    function addLogMessage(message) {
        let logContent = document.getElementById("logContent");
        if (logContent) {
            logContent.innerHTML += message + "<br>";
            // 自动滚动到底部
            logContent.scrollTop = logContent.scrollHeight;
        }
    }

    /**
     * 更新面板上显示的已捕获链接数量
     */
    function updateDashCount() {
        let dashCountElem = document.getElementById("dashCount");
        if (dashCountElem) {
            dashCountElem.innerText = `已捕获 ${capturedUrls.size} 个链接`;
        }
    }

    /**
     * 监听网络请求，捕获 dash 链接
     */
    function monitorNetworkRequests() {
        // 保存原始的 XMLHttpRequest.open 方法
        const originalOpen = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(method, url) {
            // 检查 URL 是否是我们想要的 dash 请求
            if (typeof url === "string" && url.includes("https://cache.video.iqiyi.com/dash?tvid=")) {
                // 如果是新的链接，则添加到集合中
                if (!capturedUrls.has(url)) {
                    capturedUrls.add(url);
                    updateDashCount();
                    addLogMessage(`[XHR] 捕获: ${url.substring(0, 80)}...`);
                }
            }
            // 调用原始的 open 方法，确保请求正常发出
            return originalOpen.apply(this, arguments);
        };

        // 保存原始的 window.fetch 方法
        const originalFetch = window.fetch;
        window.fetch = function(...args) {
            let url = args[0] instanceof Request ? args[0].url : args[0];
             // 检查 URL 是否是我们想要的 dash 请求
            if (typeof url === "string" && url.includes("https://cache.video.iqiyi.com/dash?tvid=")) {
                 // 如果是新的链接，则添加到集合中
                if (!capturedUrls.has(url)) {
                    capturedUrls.add(url);
                    updateDashCount();
                    addLogMessage(`[Fetch] 捕获: ${url.substring(0, 80)}...`);
                }
            }
            // 调用原始的 fetch 方法，确保请求正常发出
            return originalFetch.apply(this, args);
        };
    }

    // --- 脚本主入口 ---
    // 等待页面加载完成后执行
    window.addEventListener('load', () => {
        createPanel();
        monitorNetworkRequests();
        addLogMessage("初始化完成，开始监听...");
    });

})();