// ==UserScript==
// @name         SMMS 批量图像清理增强版（常驻+即时处理）
// @namespace    http://tampermonkey.net/
// @version      1.7
// @description  自动批量删除 SMMS 图床图片，支持常驻控制面板、即时处理、暂停、记忆页码、自动点击确认弹窗
// @author       Central
// @match        https://smms.app/home/picture?page=*
// @grant        none
// ==/UserScript==

(function () {
    'use strict';

    const deleteDelay = 10000; // 删除操作延迟 10 秒
    const checkboxSelector = '.select-all-checkbox'; // 全选框选择器
    const deleteBtnSelector = '#delete-selected'; // 删除按钮选择器
    const confirmBtnSelector = '.swal2-confirm'; // 确认弹窗选择器
    const stopKey = 'smms-auto-stop-page';
    const autoRunKey = 'smms-auto-is-running';

    let isRunning = localStorage.getItem(autoRunKey) === 'true';
    let stopPage = parseInt(localStorage.getItem(stopKey)) || 1;
    let panelCreated = false;

    // 获取当前页面
    function getCurrentPage() {
        const url = new URL(location.href);
        const page = parseInt(url.searchParams.get("page"));
        return isNaN(page) ? 1 : page;
    }

    // 跳转到指定页面
    function gotoPage(p) {
        const url = new URL(location.href);
        url.searchParams.set("page", p);
        location.href = url.href;
    }

    // 日志输出
    function log(msg) {
        const area = document.querySelector("#smms-logs");
        if (area) {
            const time = new Date().toLocaleTimeString();
            area.value += `[${time}] ${msg}\n`;
            area.scrollTop = area.scrollHeight;
        }
    }

    // 创建控制面板
    function createControlPanel() {
        if (panelCreated) return;
        panelCreated = true;

        const panel = document.createElement("div");
        panel.id = "smms-control-panel";
        panel.style.position = "fixed";
        panel.style.top = "20px";
        panel.style.right = "20px";
        panel.style.zIndex = "9999";
        panel.style.padding = "10px";
        panel.style.background = "white";
        panel.style.border = "1px solid #ccc";
        panel.style.borderRadius = "8px";
        panel.style.fontSize = "14px";
        panel.style.boxShadow = "0 0 10px rgba(0,0,0,0.2)";
        panel.innerHTML = `
            <div><b>SMMS清理工具</b></div>
            <div>停止页码: <input id="stop-page" type="number" value="${stopPage}" style="width:50px"/></div>
            <button id="toggle-run">${isRunning ? "⏸ 暂停" : "▶ 开始"}</button>
            <textarea id="smms-logs" rows="10" cols="30" readonly style="margin-top:8px;width:100%;"></textarea>
        `;
        document.body.appendChild(panel);

        document.getElementById("toggle-run").onclick = () => {
            isRunning = !isRunning;
            localStorage.setItem(autoRunKey, isRunning);
            document.getElementById("toggle-run").innerText = isRunning ? "⏸ 暂停" : "▶ 开始";
            if (isRunning) {
                log("🟢 用户启动自动删除");
                tryStartDeleting();
            } else {
                log("⏸ 用户暂停自动删除");
            }
        };

        document.getElementById("stop-page").addEventListener("input", (e) => {
            stopPage = parseInt(e.target.value) || 1;
            localStorage.setItem(stopKey, stopPage);
            log(`🔧 停止页码设置为 ${stopPage}`);
        });

        log("✅ 控制面板创建完成");
    }

    // 点击确认弹窗
    function clickConfirmIfExists() {
        const confirmBtn = document.querySelector(confirmBtnSelector);
        if (confirmBtn && confirmBtn.offsetParent !== null) {
            confirmBtn.click();
            log("✅ 已点击确认弹窗按钮");
            return true;
        }
        return false;
    }

    // 删除逻辑
    async function startDeleting() {
        const currentPage = getCurrentPage();
        log(`🧹 正在处理第 ${currentPage} 页，isRunning: ${isRunning}`);

        // 检查全选框
        const checkbox = document.querySelector(checkboxSelector);
        if (checkbox && !checkbox.checked) {
            checkbox.click();
            log("☑️ 已点击全选");
        } else if (!checkbox) {
            log("❌ 未找到全选框 (或本页已空)，跳转到上一页");
            const nextPage = currentPage - 1;
            if (nextPage >= stopPage) {
                gotoPage(nextPage);
            } else {
                log(`✅ 已到达停止页 ${stopPage}，停止运行`);
                isRunning = false;
                localStorage.setItem(autoRunKey, 'false');
                if (document.getElementById("toggle-run")) {
                    document.getElementById("toggle-run").innerText = "▶ 开始";
                }
            }
            return;
        } else if (checkbox.checked) {
            log("☑️ 全选框已被选中 (可能上次未刷新)");
        }

        // 点击删除按钮
        setTimeout(() => {
            const deleteBtn = document.querySelector(deleteBtnSelector);
            if (deleteBtn) {
                deleteBtn.click();
                log("🗑️ 已点击删除按钮，准备处理弹窗...");
            } else {
                log("❌ 未找到删除按钮，停止当前页面处理");
                return;
            }

            // 等待弹窗并点击确认
            const interval = setInterval(() => {
                if (clickConfirmIfExists()) {
                    clearInterval(interval);

                    // 等待删除操作完成
                    setTimeout(() => {
                        const nextPage = currentPage - 1;

                        if (nextPage < stopPage) {
                            log(`✅ 已删除第 ${currentPage} 页 (已达停止页 ${stopPage}，nextPage=${nextPage})，停止运行`);
                            isRunning = false;
                            localStorage.setItem(autoRunKey, 'false');
                            if (document.getElementById("toggle-run")) {
                                document.getElementById("toggle-run").innerText = "▶ 开始";
                            }
                        } else if (isRunning) {
                            log(`➡️ 删除完成，跳转第 ${nextPage} 页`);
                            gotoPage(nextPage);
                        } else {
                            log("⏸️ 用户已暂停，停止跳转");
                        }
                    }, deleteDelay);
                }
            }, 500);

            // 弹窗超时
            setTimeout(() => {
                clearInterval(interval);
                log("❌ 弹窗未出现，停止等待");
            }, 10000);
        }, 1000);
    }

    // 尝试开始删除，检查页面是否就绪
    function tryStartDeleting(attempt = 1, maxAttempts = 5) {
        if (!isRunning) {
            log("⏸ 自动运行已暂停，停止尝试");
            return;
        }

        const checkbox = document.querySelector(checkboxSelector);
        if (checkbox || document.querySelector('.no-data')) { // 假设空页面有 .no-data 类，需根据实际调整
            log("✅ 页面内容已就绪，开始删除");
            startDeleting();
            return;
        }

        if (attempt > maxAttempts) {
            log("❌ 页面内容加载超时，停止尝试");
            return;
        }

        log(`⏳ 页面内容未就绪，第 ${attempt} 次尝试...`);
        setTimeout(() => tryStartDeleting(attempt + 1, maxAttempts), 1000);
    }

    // 初始化脚本
    function init() {
        // 立即创建控制面板
        createControlPanel();

        // 监听页面导航变化
        let lastUrl = location.href;
        new MutationObserver(() => {
            const currentUrl = location.href;
            if (currentUrl !== lastUrl && isRunning) {
                lastUrl = currentUrl;
                log("🟢 检测到页面导航变化，重新尝试删除");
                tryStartDeleting();
            }
        }).observe(document, { subtree: true, childList: true });

        // 初始尝试删除
        if (isRunning) {
            log("🟢 自动运行中，尝试开始删除");
            tryStartDeleting();
        } else {
            log("⏸ 当前暂停");
        }
    }

    // 立即执行初始化
    init();
})();