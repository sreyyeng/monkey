// ==UserScript==
// @name         ReleaseBB Chinese Subtitle Finder (Enhanced)
// @namespace    http://tampermonkey.net/
// @version      5.0
// @description  精确查找 rlsbb.ru 上的中文字幕电影。高亮并置顶2023+新片, 动态扫描 Movies 和 Foreign-Movies (各3页)。
// @author       Your Name (Updated by Gemini)
// @match        https://rlsbb.ru/category/movies/
// @match        https://rlsbb.ru/category/movies/page/*
// @match        https://rlsbb.ru/category/foreign-movies/
// @match        https://rlsbb.ru/category/foreign-movies/page/*
// @grant        none
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
            max-height: 80vh; /* 使用vh确保在不同屏幕下的高度 */
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
        }
        #scan-legend span {
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
        .badge-page-mov { background: #5bc0de; } /* 蓝色: Movies */
        .badge-page-for { background: #5cb85c; } /* 绿色: Foreign */

        /* 🔴 2023+ 新片样式 */
        .badge-year-new { background: #d90429; }
        .movie-item-new {
            background: #fff0f0; /* 浅红背景 */
            border-left: 4px solid #d90429;
        }
        .movie-item-new a { color: #d90429; } /* 深红文字 */

        /* ⚪ 2023 以前旧片样式 */
        .badge-year-old { background: #777; }
        .movie-item-old {
            background: #f8f9fa; /* 灰色背景 */
        }
        .movie-item-old a { color: #007bff; } /* 蓝色文字 */
    `;
    document.head.appendChild(styleSheet);


    // === 创建结果显示面板 ===
    const resultsBox = document.createElement('div');
    resultsBox.id = 'chinese-subtitle-movies';
    document.body.appendChild(resultsBox);

    const title = document.createElement('h3');
    title.textContent = '🎬 有中文字幕的电影';
    resultsBox.appendChild(title);

    const legend = document.createElement('div');
    legend.id = 'scan-legend';
    legend.innerHTML = `
        <strong>图例:</strong><br>
        <span style="background: #fff0f0; border: 1px solid #d90429;"></span> <strong>2023+ 新片</strong> (红底红字)<br>
        <span style="background: #f8f9fa; border: 1px solid #ddd;"></span> <strong>2023 以前</strong> (灰底蓝字)<br>
        <span style="background: #5bc0de;"></span> <strong>MOV:</strong> Movies / <span style="background: #5cb85c;"></span> <strong>FOR:</strong> Foreign-Movies
    `;
    resultsBox.appendChild(legend);

    const stats = document.createElement('div');
    stats.id = 'stats';
    resultsBox.appendChild(stats);

    // --- 新片置顶列表 ---
    const separatorNew = document.createElement('div');
    separatorNew.className = 'results-separator';
    separatorNew.textContent = '🔥 2023+ 新片 (置顶)';
    resultsBox.appendChild(separatorNew);

    const resultsListNew = document.createElement('ul');
    resultsListNew.id = 'results-list-new';
    resultsListNew.className = 'results-list';
    resultsBox.appendChild(resultsListNew);

    // --- 旧片列表 ---
    const separatorOld = document.createElement('div');
    separatorOld.className = 'results-separator';
    separatorOld.textContent = '🎞️ 2023 以前';
    resultsBox.appendChild(separatorOld);

    const resultsListOld = document.createElement('ul');
    resultsListOld.id = 'results-list-old';
    resultsListOld.className = 'results-list';
    resultsBox.appendChild(resultsListOld);


    // === 核心查找函数 (已更新, 增加 categoryBadge 参数) ===
    function findMoviesWithChineseSubtitles(doc, pageNum, categoryBadge) {
        const articles = doc.querySelectorAll('article.post');
        let foundCount = 0;

        articles.forEach(article => {
            const entrySummary = article.querySelector('.entry-summary');
            if (!entrySummary) return;

            const paragraphs = entrySummary.querySelectorAll('p');
            let hasChineseSubtitle = false;

            paragraphs.forEach(p => {
                const text = p.textContent || p.innerText;
                if (text.includes('Subtitles:') && /\bChinese\b/i.test(text)) {
                    hasChineseSubtitle = true;
                }
            });

            if (hasChineseSubtitle) {
                const titleElement = article.querySelector('h1.entry-title a');
                if (titleElement) {
                    const movieTitle = titleElement.textContent.trim();
                    const movieLink = titleElement.href;

                    // 检查两个列表, 避免重复
                    const existingLinks = Array.from(document.querySelectorAll('#results-list-new a, #results-list-old a'));
                    const isDuplicate = existingLinks.some(link => link.href === movieLink);

                    if (!isDuplicate) {
                        let year = null;
                        const yearMatch = movieTitle.match(/\b(19\d{2}|20\d{2})\b/);
                        if (yearMatch) {
                            year = parseInt(yearMatch[0], 10);
                        }

                        const isNew = year && year >= 2023;
                        const itemClass = isNew ? 'movie-item-new' : 'movie-item-old';
                        const yearBadgeClass = isNew ? 'badge-year-new' : 'badge-year-old';
                        const pageBadgeClass = (categoryBadge === 'MOV') ? 'badge-page-mov' : 'badge-page-for';

                        const listItem = document.createElement('li');
                        listItem.className = `movie-item ${itemClass}`;

                        const pageBadge = document.createElement('span');
                        pageBadge.className = `badge ${pageBadgeClass}`;
                        pageBadge.textContent = `${categoryBadge}-P${pageNum}`;

                        const yearBadge = document.createElement('span');
                        yearBadge.className = `badge ${yearBadgeClass}`;
                        yearBadge.textContent = year || '----';

                        const link = document.createElement('a');
                        link.href = movieLink;
                        link.textContent = movieTitle
                            .replace(/\b(19\d{2}|20\d{2})\b/, '')
                            .replace(/\s+/g, ' ')
                            .trim();
                        link.target = '_blank';

                        listItem.appendChild(pageBadge);
                        listItem.appendChild(yearBadge);
                        listItem.appendChild(link);

                        // *** 置顶逻辑: 添加到对应的列表 ***
                        if (isNew) {
                            resultsListNew.appendChild(listItem);
                        } else {
                            resultsListOld.appendChild(listItem);
                        }

                        foundCount++;
                    }
                }
            }
        });
        return foundCount;
    }

    // === 获取当前页码和分类 (新函数) ===
    function getCurrentCategoryInfo() {
        const path = window.location.pathname;
        const pageMatch = path.match(/\/page\/(\d+)/);
        const currentPage = pageMatch ? parseInt(pageMatch[1], 10) : 1;

        let currentCategory = 'unknown';
        if (path.includes('/category/movies/')) {
            currentCategory = 'movies';
        } else if (path.includes('/category/foreign-movies/')) {
            currentCategory = 'foreign-movies';
        }

        return { currentPage, currentCategory };
    }

    // === 主扫描函数 (已重构) ===
    async function runScan() {
        const { currentPage, currentCategory } = getCurrentCategoryInfo();
        const totalPagesToScan = 3; // 每个分类扫描3页
        const startPage = currentPage;
        const endPage = currentPage + totalPagesToScan - 1;

        let totalFound = 0;
        stats.textContent = `🔄 准备扫描 P${startPage}-P${endPage} (Movies & Foreign)...`;

        const categories = [
            { id: 'movies', badge: 'MOV' },
            { id: 'foreign-movies', badge: 'FOR' }
        ];

        // 1. 创建所有扫描任务
        const scanTasks = [];
        for (let i = startPage; i <= endPage; i++) {
            for (const cat of categories) {
                const isCurrent = (i === currentPage && cat.id === currentCategory);
                const pageUrl = (i === 1)
                    ? `https://rlsbb.ru/category/${cat.id}/`
                    : `https://rlsbb.ru/category/${cat.id}/page/${i}/`;

                scanTasks.push({
                    pageNum: i,
                    categoryBadge: cat.badge,
                    isCurrent,
                    url: pageUrl
                });
            }
        }

        // 2. 执行扫描任务
        for (const task of scanTasks) {
            let pageDoc;
            let pageFoundCount = 0;

            stats.textContent = `🔍 扫描 P${task.pageNum} (${task.categoryBadge})... (共 ${totalFound} 部)`;

            try {
                if (task.isCurrent) {
                    // 1. 扫描当前页 (无需fetch)
                    pageDoc = document;
                } else {
                    // 2. 扫描其他页面 (需要fetch)
                    const response = await fetch(task.url);
                    if (!response.ok) throw new Error(`HTTP ${response.status}`);

                    const html = await response.text();
                    const parser = new DOMParser();
                    pageDoc = parser.parseFromString(html, 'text/html');

                    // 添加延迟避免请求过快
                    await new Promise(resolve => setTimeout(resolve, 200));
                }

                pageFoundCount = findMoviesWithChineseSubtitles(pageDoc, task.pageNum, task.categoryBadge);
                totalFound += pageFoundCount;
                stats.textContent = `✅ P${task.pageNum} (${task.categoryBadge}) 完毕. (共 ${totalFound} 部)`;

            } catch (error) {
                console.error(`[RlsBB Script] 抓取 ${task.url} 失败:`, error);
                stats.textContent = `⚠️ P${task.pageNum} (${task.categoryBadge}) 扫描失败. (共 ${totalFound} 部)`;
            }
        }

        // 3. 最终总结
        stats.textContent = `🎉 扫描完成 (P${startPage}-${endPage}, 2个分类)! 共找到 ${totalFound} 部电影`;

        // 4. 检查空列表并添加占位符
        if (resultsListNew.children.length === 0) {
            resultsListNew.innerHTML = '<li class="no-results-item">在扫描范围内暂无2023+新片</li>';
        }
        if (resultsListOld.children.length === 0) {
            resultsListOld.innerHTML = '<li class="no-results-item">在扫描范围内暂无旧片</li>';
        }
    }

    // 启动扫描
    runScan();

})();