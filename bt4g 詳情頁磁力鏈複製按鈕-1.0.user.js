// ==UserScript==
// @name         bt4g 詳情頁磁力鏈複製按鈕
// @namespace    http://tampermonkey.net/
// @version      1.0
// @description  在 bt4gprx.com 的詳情頁上添加一個一鍵複製磁力鏈的按鈕
// @author       You
// @match        https://bt4gprx.com/magnet/*
// @grant        GM_setClipboard
// ==/UserScript==

(function() {
    'useRECT';

    // 1. 查找包含磁力鏈的 "Magnet Link" 按鈕
    // (根據你提供的 HTML，這個選擇器是正確的)
    const magnetButton = document.querySelector('.card-body a[href^="//downloadtorrentfile.com/hash/"]');

    if (magnetButton) {
        try {
            // 2. 從按鈕的 href 中提取 hash 和 name
            const url = new URL(magnetButton.href, window.location.origin);
            const hash = url.pathname.split('/')[2];
            const name = url.searchParams.get('name') || 'unknown';

            // 3. 構造標準的磁力鏈 (magnet link)
            const magnetLink = `magnet:?xt=urn:btih:${hash}&dn=${encodeURIComponent(name)}`;

            // 4. 創建新的 "複製" 按鈕
            const copyButton = document.createElement('a'); // 使用 <a> 標籤讓樣式和兄弟按鈕一致
            copyButton.textContent = '複製磁力鏈';
            copyButton.href = '#'; // 只是個佔位符
            copyButton.classList.add('btn', 'btn-success', 'me-2'); // 使用 'btn-success' (綠色) 樣式
            copyButton.style.marginLeft = "5px"; // 和前一個按鈕稍微分開

            // 5. 添加點擊事件
            copyButton.addEventListener('click', (e) => {
                e.preventDefault(); // 阻止 <a> 標籤的默認跳轉
                e.stopPropagation();

                GM_setClipboard(magnetLink);

                // 提供視覺反饋
                const originalText = copyButton.textContent;
                copyButton.textContent = '已複製!';
                copyButton.classList.remove('btn-success');
                copyButton.classList.add('btn-secondary'); // 變成灰色表示已點擊

                setTimeout(() => {
                    copyButton.textContent = originalText;
                    copyButton.classList.remove('btn-secondary');
                    copyButton.classList.add('btn-success');
                }, 2000);
            });

            // 6. 將新按鈕插入到原 "Magnet Link" 按鈕的後面
            magnetButton.after(copyButton);

        } catch (error) {
            console.error('[BT4G 複製腳本] 處理磁力鏈時出錯:', error);
        }
    } else {
        console.error('[BT4G 複製腳本] 未能在頁面中找到 "Magnet Link" 按鈕。');
    }
})();