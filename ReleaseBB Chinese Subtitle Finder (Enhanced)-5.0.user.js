// ==UserScript==
// @name        ReleaseBB Chinese Subtitle Finder (Enhanced + Suspected + Foldable)
// @namespace   http://tampermonkey.net/
// @version     5.2
// @description 精确查找 rlsbb.ru 上的中文字幕电影。高亮 2023+ 新片；疑似资源(字幕>5)标黄；2023以前旧片默认折叠并显示数量。
// @author      Your Name (Updated by Gemini)
// @match       https://rlsbb.ru/category/movies/
// @match       https://rlsbb.ru/category/movies/page/*
// @match       https://rlsbb.ru/category/foreign-movies/
// @match       https://rlsbb.ru/category/foreign-movies/page/*
// @grant       none
// ==/UserScript==

(function() {
    'use strict';

    // === 注入CSS样式 ===
    const styleSheet = document.createElement('style');
    styleSheet.type = 'text/css';
    styleSheet.innerText = `
        #chinese-subtitle-movies {
            position: fixed;
            top: 10px;
            right: 10px;
            width: 380px;
            max-height: 80vh;
            overflow-y: auto;
            background-color: #fff;
            border: 3px solid #ff6b6b;
            border-radius: 8px;
            padding: 15px;
            z-index: 10000;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
            font-family: Arial, sans-serif;
        }
        #chinese-subtitle-movies h3 {
            margin-top: 0;
            color: #ff6b6b;
            border-bottom: 2px solid #ff6b6b;
            padding-bottom: 10px;
        }
        #scan-legend {
            font-size: 11px;
            color: #333;
            background: #f4f4f4;
            padding: 8px;
            border-radius: 4px;
            margin: 10px 0;
            line-height: 1.6;
        }
        #scan-legend span.color-box {
            display: inline-block;
            width: 12px;
            height: 12px;
            margin-right: 4px;
            border-radius: 3px;
            vertical-align: middle;
        }
        #stats {
            margin: 10px 0;
            font-size: 12px;
            color: #666;
            font-weight: bold;
        }
        .results-separator {
            margin-top: 15px;
            font-size: 14px;
            font-weight: bold;
            color: #444;
            border-bottom: 1px solid #ccc;
            padding-bottom: 5px;
            background: #eee; /* 轻微背景区分 */
            padding: 5px 8px;
            border-radius: 4px;
        }
        /* 可折叠标题的样式 */
        .results-separator.clickable {
            cursor: pointer;
            user-select: none; /* 防止双击选中文本 */
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        .results-separator.clickable:hover {
            background-color: #e0e0e0;
        }

        .results-list {
            list-style: none;
            padding: 0;
            margin: 0;
        }
        .no-results-item {
            color: #999;
            text-align: center;
            padding: 10px;
            font-style: italic;
            font-size: 12px;
        }
        .movie-item {
            margin: 8px 0;
            padding: 8px 10px;
            border-radius: 4px;
            display: flex;
            align-items: center;
            gap: 6px;
        }
        .movie-item a {
            text-decoration: none;
            font-size: 13px;
            font-weight: 500;
            flex-grow: 1;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
        }
        .movie-item a:hover {
            text-decoration: underline;
        }

        /* 徽章基础样式 */
        .badge {
            font-size: 10px;
            padding: 3px 5px;
            border-radius: 4px;
            color: #fff;
            font-weight: bold;
            flex-shrink: 0;
        }
        .badge-page-mov { background: #5bc0de; }
        .badge-page-for { background: #5cb85c; }
        
        /* 🔴 确认为中文 - 2023+ 新片 */
        .movie-item-new {
            background: #fff0f0;
            border-left: 4px solid #d90429;
        }
        .movie-item-new a { color: #d90429; }
        .badge-year-new { background: #d90429; }

        /* ⚪ 确认为中文 - 旧片 */
        .movie-item-old {
            background: #f8f9fa;
        }
        .movie-item-old a { color: #007bff; }
        .badge-year-old { background: #777; }

        /* 🟡 疑似 */
        .movie-item-suspect {
            background: #fff9db;
            border-left: 4px solid #fcc419;
        }
        .movie-item-suspect a { color: #b76e00; }
        .badge-suspect { background: #fcc419; color: #000; } 
    `;
    document.head.appendChild(styleSheet);


    // === 创建结果显示面板 ===
    const resultsBox = document.createElement('div');
    resultsBox.id = 'chinese-subtitle-movies';
    document.body.appendChild(resultsBox);

    const title = document.createElement('h3');
    title.textContent = '🎬 电影字幕查找器';
    resultsBox.appendChild(title);

    const legend = document.createElement('div');
    legend.id = 'scan-legend';
    legend.innerHTML = `
        <strong>图例:</strong><br>
        <span class="color-box" style="background: #fff0f0; border: 1px solid #d90429;"></span> <strong>2023+ 含中文</strong> (红)<br>
        <span class="color-box" style="background: #f8f9fa; border: 1px solid #ddd;"></span> <strong>旧片 含中文</strong> (灰)<br>
        <span class="color-box" style="background: #fff9db; border: 1px solid #fcc419;"></span> <strong>疑似(字幕>5)</strong> (黄)<br>
    `;
    resultsBox.appendChild(legend);

    const stats = document.createElement('div');
    stats.id = 'stats';
    resultsBox.appendChild(stats);

    // --- 新片列表 (不折叠) ---
    const separatorNew = document.createElement('div');
    separatorNew.className = 'results-separator';
    separatorNew.textContent = '🔥 2023+ 新片 (置顶)';
    resultsBox.appendChild(separatorNew);

    const resultsListNew = document.createElement('ul');
    resultsListNew.id = 'results-list-new';
    resultsListNew.className = 'results-list';
    resultsBox.appendChild(resultsListNew);

    // --- 旧片列表 (可折叠) ---
    const separatorOld = document.createElement('div');
    separatorOld.className = 'results-separator clickable'; // 添加 clickable 类
    separatorOld.title = '点击展开/收起';
    resultsBox.appendChild(separatorOld);

    const resultsListOld = document.createElement('ul');
    resultsListOld.id = 'results-list-old';
    resultsListOld.className = 'results-list';
    resultsListOld.style.display = 'none'; // 🔴 默认隐藏
    resultsBox.appendChild(resultsListOld);

    // === 辅助函数：更新旧片标题计数 ===
    function updateOldListHeader() {
        // 计算实际的电影条目数 (排除 no-results 提示)
        const count = resultsListOld.querySelectorAll('.movie-item').length;
        const isHidden = resultsListOld.style.display === 'none';
        const arrow = isHidden ? '▶' : '▼'; // 使用三角形符号表示状态
        separatorOld.textContent = `🎞️ 2023 以前 (${count}) ${arrow}`;
    }

    // 初始化标题
    updateOldListHeader();

    // === 点击事件：折叠/展开 ===
    separatorOld.addEventListener('click', () => {
        if (resultsListOld.style.display === 'none') {
            resultsListOld.style.display = 'block';
        } else {
            resultsListOld.style.display = 'none';
        }
        updateOldListHeader(); // 更新箭头方向
    });


    // === 核心查找函数 ===
    function findMoviesWithChineseSubtitles(doc, pageNum, categoryBadge) {
        const articles = doc.querySelectorAll('article.post');
        let foundCount = 0;

        articles.forEach(article => {
            const entrySummary = article.querySelector('.entry-summary');
            if (!entrySummary) return;

            const paragraphs = entrySummary.querySelectorAll('p');
            let detectionStatus = 'none'; 

            paragraphs.forEach(p => {
                const text = p.textContent || p.innerText;
                if (text.includes('Subtitles:')) {
                    if (/\bChinese\b/i.test(text)) {
                        detectionStatus = 'confirmed';
                    } else if (detectionStatus !== 'confirmed') {
                        const subsPart = text.split('Subtitles:')[1];
                        if (subsPart) {
                            const langCount = subsPart.split(',').length;
                            if (langCount > 5) {
                                detectionStatus = 'suspected';
                            }
                        }
                    }
                }
            });

            if (detectionStatus !== 'none') {
                const titleElement = article.querySelector('h1.entry-title a');
                if (titleElement) {
                    const movieTitle = titleElement.textContent.trim();
                    const movieLink = titleElement.href;
                    const existingLinks = Array.from(document.querySelectorAll('#results-list-new a, #results-list-old a'));
                    const isDuplicate = existingLinks.some(link => link.href === movieLink);

                    if (!isDuplicate) {
                        let year = null;
                        const yearMatch = movieTitle.match(/\b(19\d{2}|20\d{2})\b/);
                        if (yearMatch) year = parseInt(yearMatch[0], 10);

                        const isNew = year && year >= 2023;
                        let itemClass = '', statusBadgeHtml = '';

                        if (detectionStatus === 'confirmed') {
                            itemClass = isNew ? 'movie-item-new' : 'movie-item-old';
                        } else {
                            itemClass = 'movie-item-suspect';
                            statusBadgeHtml = `<span class="badge badge-suspect">❓疑似</span>`;
                        }

                        const pageBadgeClass = (categoryBadge === 'MOV') ? 'badge-page-mov' : 'badge-page-for';
                        const yearBadgeClass = isNew ? 'badge-year-new' : 'badge-year-old';

                        const listItem = document.createElement('li');
                        listItem.className = `movie-item ${itemClass}`;
                        
                        const pageBadge = `<span class="badge ${pageBadgeClass}">${categoryBadge}-P${pageNum}</span>`;
                        const yearBadge = `<span class="badge ${yearBadgeClass}">${year || '----'}</span>`;
                        const linkHtml = `<a href="${movieLink}" target="_blank">${movieTitle.replace(/\b(19\d{2}|20\d{2})\b/, '').replace(/\s+/g, ' ').trim()}</a>`;

                        listItem.innerHTML = `${pageBadge} ${yearBadge} ${statusBadgeHtml} ${linkHtml}`;

                        if (isNew) {
                            resultsListNew.appendChild(listItem);
                        } else {
                            resultsListOld.appendChild(listItem);
                            // 🔴 每次添加旧片后，立即更新计数标题
                            updateOldListHeader();
                        }
                        foundCount++;
                    }
                }
            }
        });
        return foundCount;
    }

    // === 扫描控制逻辑 ===
    function getCurrentCategoryInfo() {
        const path = window.location.pathname;
        const pageMatch = path.match(/\/page\/(\d+)/);
        const currentPage = pageMatch ? parseInt(pageMatch[1], 10) : 1;
        let currentCategory = 'unknown';
        if (path.includes('/category/movies/')) currentCategory = 'movies';
        else if (path.includes('/category/foreign-movies/')) currentCategory = 'foreign-movies';
        return { currentPage, currentCategory };
    }

    async function runScan() {
        const { currentPage, currentCategory } = getCurrentCategoryInfo();
        const totalPagesToScan = 3; 
        const startPage = currentPage;
        const endPage = currentPage + totalPagesToScan - 1;

        let totalFound = 0;
        stats.textContent = `🔄 准备扫描 P${startPage}-P${endPage}...`;

        const categories = [
            { id: 'movies', badge: 'MOV' },
            { id: 'foreign-movies', badge: 'FOR' }
        ];

        const scanTasks = [];
        for (let i = startPage; i <= endPage; i++) {
            for (const cat of categories) {
                const isCurrent = (i === currentPage && cat.id === currentCategory);
                const pageUrl = (i === 1) ? `https://rlsbb.ru/category/${cat.id}/` : `https://rlsbb.ru/category/${cat.id}/page/${i}/`;
                scanTasks.push({ pageNum: i, categoryBadge: cat.badge, isCurrent, url: pageUrl });
            }
        }

        for (const task of scanTasks) {
            let pageDoc;
            let pageFoundCount = 0;
            stats.textContent = `🔍 扫描 P${task.pageNum} (${task.categoryBadge})... (共 ${totalFound} 部)`;

            try {
                if (task.isCurrent) {
                    pageDoc = document;
                } else {
                    const response = await fetch(task.url);
                    if (!response.ok) throw new Error(`HTTP ${response.status}`);
                    const html = await response.text();
                    const parser = new DOMParser();
                    pageDoc = parser.parseFromString(html, 'text/html');
                    await new Promise(resolve => setTimeout(resolve, 200));
                }

                pageFoundCount = findMoviesWithChineseSubtitles(pageDoc, task.pageNum, task.categoryBadge);
                totalFound += pageFoundCount;
                stats.textContent = `✅ P${task.pageNum} (${task.categoryBadge}) 完毕. (共 ${totalFound} 部)`;

            } catch (error) {
                console.error(`[RlsBB Script] 抓取失败:`, error);
            }
        }

        stats.textContent = `🎉 扫描完成! 共找到 ${totalFound} 部`;

        if (resultsListNew.children.length === 0) resultsListNew.innerHTML = '<li class="no-results-item">暂无2023+新片</li>';
        
        // 如果旧片列表是空的，显示“暂无”提示（即便折叠也能保持逻辑一致）
        if (resultsListOld.querySelectorAll('.movie-item').length === 0) {
             resultsListOld.innerHTML = '<li class="no-results-item">暂无旧片</li>';
        }
        updateOldListHeader(); // 最后再更新一次以防万一
    }

    runScan();

})();
