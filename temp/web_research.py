#!/usr/bin/env python3
import os
import re
import json
import requests
from bs4 import BeautifulSoup
from datetime import datetime
from typing import Dict, List, Any

def search_web(query: str, max_results: int = 5) -> Dict[str, Any]:
    headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36'
    }
    
    try:
        encoded_query = query.replace(' ', '+')
        response = requests.get(f'https://html.duckduckgo.com/html/?q={encoded_query}', headers=headers)
        
        if response.status_code != 200:
            return {"error": f"Search failed with status {response.status_code}"}
            
        soup = BeautifulSoup(response.text, 'html.parser')
        results = []
        
        for result in soup.select('.result__body')[:max_results]:
            title_elem = result.select_one('.result__title')
            link_elem = result.select_one('.result__url')
            snippet_elem = result.select_one('.result__snippet')
            
            if title_elem and link_elem:
                title = title_elem.get_text().strip()
                url = link_elem.get('href') if link_elem.has_attr('href') else link_elem.get_text().strip()
                snippet = snippet_elem.get_text().strip() if snippet_elem else ""
                
                if '/d.js' in url:
                    url_match = re.search(r'uddg=([^&]+)', url)
                    if url_match:
                        url = requests.utils.unquote(url_match.group(1))
                
                results.append({
                    "title": title,
                    "url": url,
                    "snippet": snippet
                })
        
        return {"results": results}
    
    except Exception as e:
        return {"error": str(e)}

def extract_content(url: str) -> Dict[str, Any]:
    headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36'
    }
    
    try:
        response = requests.get(url, headers=headers, timeout=10)
        if response.status_code != 200:
            return {"error": f"Failed to retrieve content: Status {response.status_code}"}
        
        soup = BeautifulSoup(response.text, 'html.parser')
        
        for element in soup(['script', 'style', 'nav', 'footer', 'header', 'aside']):
            element.decompose()
        
        title = soup.title.string if soup.title else "Unknown Title"
        
        main_content = soup.find('main') or soup.find('article') or soup.find('div', class_='content')
        
        if main_content:
            content = main_content.get_text(separator='
')
        else:
            content = soup.get_text(separator='
')
        
        content = re.sub(r'
+', '
', content)
        content = re.sub(r'\s+', ' ', content)
        content = content.strip()
        
        return {
            "title": title,
            "content": content,
            "url": url
        }
    
    except Exception as e:
        return {"error": f"Error extracting content: {str(e)}"}

def summarize_content(content: str, max_length: int = 2000) -> str:
    if len(content) <= max_length:
        return content
    
    truncated = content[:max_length]
    last_period = truncated.rfind('.')
    
    if last_period > 0:
        return content[:last_period + 1]
    else:
        return truncated

def main():
    query = input("Enter research topic: ")
    search_results = search_web(query)
    
    if "error" in search_results:
        print(f"Search error: {search_results['error']}")
        return
    
    sources = []
    for result in search_results.get("results", []):
        print(f"Processing: {result['title']}")
        content_data = extract_content(result['url'])
        
        if "error" not in content_data:
            content_data["content"] = summarize_content(content_data["content"])
            sources.append(content_data)
        else:
            print(f"Error extracting content: {content_data['error']}")
    
    research_data = {
        "query": query,
        "timestamp": datetime.utcnow().isoformat(),
        "sources": sources,
        "summary": f"Research on '{query}' found {len(sources)} sources."
    }
    
    research_filename = re.sub(r'[\/*?:"<>|]', "_", f"{query[:30]}.json")
    research_path = os.path.join(".", research_filename)
    
    with open(research_path, 'w', encoding='utf-8') as f:
        json.dump(research_data, f, indent=2)
    
    print(f"Research completed! Results saved to: {research_path}")

if __name__ == "__main__":
    main()
