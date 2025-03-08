#!/usr/bin/env python3
import os
import sys
import json
import re
import tiktoken
import nltk
from nltk.tokenize import sent_tokenize
import argparse

def count_tokens(text: str, encoding_name: str = "cl100k_base") -> int:
    """Count the number of tokens in a text string.
    
    Args:
        text: The text to tokenize
        encoding_name: Name of the tokenizer encoding to use
        
    Returns:
        Number of tokens in the text
    """
    encoding = tiktoken.get_encoding(encoding_name)
    return len(encoding.encode(text))

def chunk_text(text, max_tokens=8000, overlap_tokens=500):
    """Split text into chunks of approximately max_tokens with overlap."""
    # First split into sentences
    sentences = sent_tokenize(text)
    
    chunks = []
    current_chunk = []
    current_token_count = 0
    
    for sentence in sentences:
        sentence_token_count = count_tokens(sentence)
        
        # If adding this sentence would exceed max tokens, finish the chunk
        if current_token_count + sentence_token_count > max_tokens and current_chunk:
            # Save the current chunk
            chunk_text = " ".join(current_chunk)
            chunks.append(chunk_text)
            
            # Start a new chunk with overlap
            overlap_text = []
            overlap_token_count = 0
            
            # Add sentences from the end of the previous chunk until we reach desired overlap
            for i in range(len(current_chunk) - 1, -1, -1):
                sentence_for_overlap = current_chunk[i]
                sentence_overlap_tokens = count_tokens(sentence_for_overlap)
                
                if overlap_token_count + sentence_overlap_tokens <= overlap_tokens:
                    overlap_text.insert(0, sentence_for_overlap)
                    overlap_token_count += sentence_overlap_tokens
                else:
                    break
            
            # Reset with overlap sentences
            current_chunk = overlap_text
            current_token_count = overlap_token_count
        
        # Add the current sentence to the chunk
        current_chunk.append(sentence)
        current_token_count += sentence_token_count
    
    # Add the last chunk if there's anything left
    if current_chunk:
        chunk_text = " ".join(current_chunk)
        chunks.append(chunk_text)
    
    return chunks

def detect_chapters(text):
    """Identify chapter breaks in the text."""
    # Common chapter patterns
    chapter_patterns = [
        r'(?i)^chapter\s+\d+', 
        r'(?i)^chapter\s+[IVXLCDM]+', 
        r'(?i)^\d+\.\s+',
        r'(?m)^\s*CHAPTER\s+(?:\d+|[IVXLCDM]+)'
    ]
    
    # Try to detect chapter markers
    chapter_matches = []
    for pattern in chapter_patterns:
        matches = re.finditer(pattern, text, re.MULTILINE)
        for match in matches:
            chapter_matches.append((match.start(), match.group()))
    
    # Sort by position in text
    chapter_matches.sort()
    return chapter_matches

def preserve_chapter_integrity(text, chunks, overlap_tokens_length, max_tokens):
    """Adjust chunk boundaries to avoid breaking up chapters."""
    chapter_markers = detect_chapters(text)
    if not chapter_markers:
        return chunks  # No chapters detected
    
    # Convert chapter positions to their containing chunk
    chapter_positions = []
    current_pos = 0
    for i, chunk in enumerate(chunks):
        chunk_len = len(chunk)
        for pos, marker in chapter_markers:
            if current_pos <= pos < current_pos + chunk_len:
                chapter_positions.append((i, pos - current_pos, marker))
        current_pos += chunk_len - overlap_tokens_length
    
    # Adjust chunks to respect chapter boundaries when possible
    modified_chunks = chunks.copy()
    
    # Process each chapter marker
    for i in range(len(chapter_positions) - 1):
        chunk_idx, pos_in_chunk, marker = chapter_positions[i]
        
        # If chapter marker is close to the end of a chunk, we might adjust it
        if pos_in_chunk > len(chunks[chunk_idx]) * 0.7:
            # Try to merge with next chunk if it's not too large
            if chunk_idx < len(chunks) - 1:
                if len(chunks[chunk_idx]) + len(chunks[chunk_idx + 1]) < max_tokens * 1.3:
                    modified_chunks[chunk_idx] = chunks[chunk_idx] + chunks[chunk_idx + 1]
                    modified_chunks.pop(chunk_idx + 1)
                    # Update positions of later chapters
                    chapter_positions = [(idx if idx <= chunk_idx else idx - 1, pos, m) 
                                       for idx, pos, m in chapter_positions]
    
    return modified_chunks

def save_chunks(chunks, output_dir, project_name):
    """Save chunks to individual files."""
    os.makedirs(output_dir, exist_ok=True)
    chunk_files = []
    
    for i, chunk in enumerate(chunks):
        file_path = os.path.join(output_dir, f"{project_name}_chunk_{i+1:04d}.txt")
        with open(file_path, 'w', encoding='utf-8') as f:
            f.write(chunk)
        chunk_files.append(file_path)
        
    # Create metadata file
    metadata = {
        "project_name": project_name,
        "total_chunks": len(chunks),
        "chunk_files": chunk_files,
        "token_counts": [count_tokens(chunk) for chunk in chunks]
    }
    
    with open(os.path.join(output_dir, f"{project_name}_metadata.json"), 'w') as f:
        json.dump(metadata, f, indent=2)
    
    return metadata

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='Split manuscript into chunks for processing')
    parser.add_argument('manuscript_path', help='Path to manuscript file')
    parser.add_argument('--output_dir', default='./chunks', help='Directory to save chunks')
    parser.add_argument('--project_name', required=True, help='Project name')
    parser.add_argument('--max_tokens', type=int, default=8000, help='Maximum tokens per chunk')
    parser.add_argument('--overlap_tokens', type=int, default=500, help='Token overlap between chunks')
    
    args = parser.parse_args()
    
    # Load config to get parameters
    try:
        with open("./config.json", 'r') as f:
            config = json.load(f)
            max_tokens = config.get('chunk_size', args.max_tokens)
            overlap_tokens = config.get('chunk_overlap', args.overlap_tokens)
    except:
        max_tokens = args.max_tokens
        overlap_tokens = args.overlap_tokens
    
    # Install nltk punkt if needed
    try:
        nltk.data.find('tokenizers/punkt')
    except LookupError:
        nltk.download('punkt')
    
    # Calculate approximate length of overlap in characters for chapter boundary calculations
    overlap_tokens_length = overlap_tokens * 4  # rough approximation
    
    # Read manuscript
    with open(args.manuscript_path, 'r', encoding='utf-8') as f:
        manuscript_text = f.read()
    
    # Chunk the text
    text_chunks = chunk_text(manuscript_text, max_tokens, overlap_tokens)
    
    # Preserve chapter integrity when possible
    refined_chunks = preserve_chapter_integrity(manuscript_text, text_chunks, overlap_tokens_length, max_tokens)
    
    # Save chunks
    metadata = save_chunks(refined_chunks, args.output_dir, args.project_name)
    
    print(f"Manuscript split into {len(refined_chunks)} chunks. Metadata saved.")
    print(json.dumps(metadata))
