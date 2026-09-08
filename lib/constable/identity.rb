# frozen_string_literal: true

require "digest"
require "ripper"

module Constable
  # A test's identity is a content hash of its `investigate` block body, normalized so
  # that formatting, comments and indentation don't affect it. Class name, description
  # and file path are stored alongside purely as a display label.
  #
  # Rename the class, reword the description, move the file -- body untouched, hash
  # untouched, full history carries over. Change what the test actually *does* and the
  # hash changes, so history starts fresh. That is correct, not a limitation.
  module Identity
    LENGTH = 16

    module_function

    # The stable key for a block of test code.
    def for_block(block)
      digest(normalize(source_for(block).to_s))
    end

    def for_source(source)
      digest(normalize(source.to_s))
    end

    # Cold cases have no `investigate` block to hash, so they're keyed by their file
    # and example description instead. Renaming a cold-case file resets its history --
    # an accepted tradeoff for tests that opted out of native rules.
    def for_cold_case(file, description, root: Constable.root)
      relative = file.to_s.delete_prefix("#{root}/")
      digest("cold:#{relative}:#{description}")
    end

    # Two investigations with byte-identical bodies hash to the same key, which would
    # make them one test as far as the blotter is concerned: jail one and the other goes
    # with it, and their flake histories merge into a single misleading record.
    #
    # Bodies repeat more often than the "content hash" idea suggests --
    # `attest(build(:thing, name: nil)).not_to be_valid` is the same handful of tokens in
    # every model case, and the model generator writes an identical first investigation
    # into every file it touches. So the collision is routine, not theoretical.
    #
    # When it happens, the colliding tests are re-keyed on the body *plus* their class
    # and description. The rename-survival promise is weaker for exactly those tests --
    # rewording one of them starts its history over -- which is the right trade: a
    # history that belongs to two tests at once is worse than one that resets.
    def disambiguate(base, case_name:, description:)
      digest("#{base}:#{case_name}:#{description}")
    end

    def digest(string)
      Digest::SHA256.hexdigest(string)[0, LENGTH]
    end

    # Extracts the literal source of a block. MRI can hand back the exact character
    # range via the AST; anything else falls back to slicing the file by line numbers.
    def source_for(block)
      return nil unless block.respond_to?(:source_location)

      ast_source(block) || line_source(block)
    end

    def ast_source(block)
      return nil unless defined?(RubyVM::AbstractSyntaxTree)

      node = RubyVM::AbstractSyntaxTree.of(block, keep_script_lines: true)
      node&.source
    rescue StandardError, NotImplementedError
      nil
    end

    def line_source(block)
      file, line = block.source_location
      return nil unless file && line && File.exist?(file)

      lines = File.readlines(file)
      # Without an AST we can't know where the block ends, so we scan forward balancing
      # do/end and brace depth from the opening line.
      slice = balanced_slice(lines, line - 1)
      slice&.join
    rescue StandardError
      nil
    end

    # Whitespace-normalized, comment-free, wrapper-free form of a block body.
    def normalize(source)
      body = strip_wrapper(source)
      tokens = lex(body)
      return collapse(body) unless tokens

      tokens.join(" ")
    end

    def lex(source)
      lexed = Ripper.lex(source)
      return nil if lexed.nil? || lexed.empty?

      ignored = %i[on_comment on_sp on_ignored_nl on_nl on_embdoc on_embdoc_beg on_embdoc_end]
      tokens = lexed.reject { |(_pos, type, _tok, _state)| ignored.include?(type) }
                    .map { |(_pos, _type, tok, _state)| tok.to_s.strip }
                    .reject(&:empty?)
      tokens.empty? ? nil : tokens
    rescue StandardError
      nil
    end

    def strip_wrapper(source)
      text = source.to_s.strip
      if text.start_with?("do")
        text = text.sub(/\Ado\b/, "").sub(/\bend\z/, "")
      elsif text.start_with?("{")
        text = text.sub(/\A\{/, "").sub(/\}\z/, "")
      end
      # Block parameters aren't part of what the test does.
      text.sub(/\A\s*\|[^|]*\|/, "").strip
    end

    def collapse(source)
      source.to_s.gsub(/\s+/, " ").strip
    end

    def balanced_slice(lines, start_index)
      openers = /(\bdo\b|\{)/
      depth = 0
      collected = []
      lines[start_index..]&.each do |line|
        collected << line
        stripped = line.sub(/#.*\z/, "")
        depth += stripped.scan(openers).size
        depth -= stripped.scan(/(\bend\b|\})/).size
        return collected if depth <= 0 && collected.size.positive?
      end
      collected.empty? ? nil : collected
    end
  end
end
