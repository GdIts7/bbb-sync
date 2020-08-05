# encoding: utf-8
require 'tempfile'
require 'enhanceutils'

module Gitlab
  module Git
    class ArchivingError < StandardError; end
    class InvalidBlobName < StandardError; end
    GitError = Class.new(StandardError)
    NetworkError = Class.new(StandardError)
    UnknownError = Class.new(StandardError)
    AccountError = Class.new(StandardError)

    class Repository
      include Gitlab::Git::Popen
      extend Gitlab::PathAdapter
      include Gitlab::Git::EncodingHelper

      CreateTreeError = Class.new(StandardError)
      #rugged repo object
      attr_accessor :repo
      # TODO 可以将 repo 替换成 rugged 以便区分
      alias_attribute :rugged, :repo

      attr_reader :storage, :relative_path

      class << self
        def generate_md5(file_path)
          md5 = Digest::MD5.hexdigest(File.read(file_path))
          File.open(file_path + '.md5','w+') { |file| file.puts md5 }
        end

        def archive(filename, compress_cmd, git_archive_cmd)
          File.open(filename, 'w') do |file|
            # Create a pipe to act as the '|' in 'git archive ... | gzip'
            pipe_rd, pipe_wr = IO.pipe
            # Get the compression process ready to accept data from the read end
            # of the pipe
            compress_pid = spawn(*compress_cmd, :in => pipe_rd, :out => file)
            # The read end belongs to the compression process now; we should
            # close our file descriptor for it.
            pipe_rd.close
            # Start 'git archive' and tell it to write into the write end of the
            # pipe.
            git_archive_pid = spawn(*git_archive_cmd, :out => pipe_wr)
            # The write end belongs to 'git archive' now; close it.
            pipe_wr.close
            # When 'git archive' and the compression process are finished, we are
            # done.
            Process.waitpid(git_archive_pid)
            unless $?.success?
              Gitlab::AppLogger.error "#{self.class.name}.#{__method__} error. #{git_archive_cmd}"
              raise "#{git_archive_cmd} failed"
            end

            Process.waitpid(compress_pid)
            unless $?.success?
              Gitlab::AppLogger.error "#{self.class.name}.#{__method__} error. #{compress_cmd}"
              raise "#{compress_cmd} failed"
            end
          end

          file_path = filename.chomp('.archiving')
          if File.exists?(filename)
            FileUtils.move(filename, file_path)
            generate_md5(file_path)
          end
        end

        def absolute_path(relative_path)
          File.join(Gitlab.config.gitlab.repos_path, "#{relative_path}.git")
        end

        def create_git_hook(repo_hooks_path)
          if Gitlab.config.gitlab.use_native_hook
            FileUtils.ln_sf("#{Gitlab.config.gitlab.native_hooks_path}/post-receive", "#{repo_hooks_path}/post-receive")
            FileUtils.ln_sf("#{Gitlab.config.gitlab.native_hooks_path}/pre-receive", "#{repo_hooks_path}/pre-receive")
            FileUtils.ln_sf("#{Gitlab.config.gitlab.native_hooks_path}/update", "#{repo_hooks_path}/update")
          else
            FileUtils.ln_sf("#{Gitlab.config.gitlab.hooks_path}/update", "#{repo_hooks_path}/update")
          end
        end

        # @param trunc [true, false] `true` remove old repository
        def create_repo(storage, relative_path, trunc = true)
          if discover_repo(relative_path)
            return Gitlab::Git::Repository.new(storage, relative_path) unless trunc
            rm_repo(relative_path)
          end

          path = absolute_path(relative_path)
          repo = Rugged::Repository.init_at(path, :bare)
          create_git_hook("#{path}/hooks")
          Gitlab::Git::Repository.new(storage, relative_path)
        rescue Exception => e
          Gitlab::AppLogger.error "#{self.name}.#{__method__}: #{e}. storage: #{storage}, relative_path: #{relative_path}"
          nil
        end

        def cred
          @@cred ||= Rugged::Credentials::UserPassword.new(username: Settings.gitlab['git_user'], password: Settings.gitlab['git_password'])
        end

        def discover_repo(relative_path)
          Dir.exists?(absolute_path(relative_path))
        end

        def import_repo(storage, relative_path, url, cred = nil)
          path = absolute_path(relative_path)
          repo = Rugged::Repository.clone_at(url, path, bare: true, credentials: cred)
          if repo
            create_git_hook("#{path}/hooks")
            Gitlab::Git::Repository.new(storage, relative_path)
          end
        rescue Exception => e
          Gitlab::AppLogger.error "#{self.name}.#{__method__}: #{e}. storage: #{storage}, relative_path: #{relative_path}, url: #{url}"
          nil
        end

        def mv_repo(relative_path, suffix = '.del')
          new_path = timestamp_path(relative_path, suffix)
          FileUtils.mv(absolute_path(relative_path), new_path)
          FileUtils.touch(new_path)
        end

        def rm_repo(relative_path)
          mv_repo(relative_path, '.del') if discover_repo(relative_path)
        rescue Exception => e
          Gitlab::AppLogger.error "#{self.name}.#{__method__}: #{e}. relative_path: #{relative_path}"
        end

        def transfer_repo(relative_path)
          mv_repo(relative_path, '.trans')
        rescue Exception => e
          Gitlab::AppLogger.error "#{self.name}.#{__method__}: #{e}. relative_path: #{relative_path}"
        end

        def timestamp_path(relative_path, postfix = '.git')
          File.join(Gitlab.config.gitlab.repos_path, "#{relative_path}_#{dir_last_update_time(relative_path)}_#{Time.now.to_i}#{postfix}")
        end

        def dir_last_update_time(relative_path)
          File::ctime(absolute_path(relative_path)).to_i
        end
      end

      def initialize(storage, relative_path)
        @storage = storage
        @relative_path = relative_path

        @repo = Rugged::Repository.bare(self.class.absolute_path(@relative_path))
      rescue Exception => e
        nil
      end

      def ==(other)
        other.is_a?(self.class) && [storage, relative_path] == [other.storage, other.relative_path]
      end

      alias_method :eql?, :==

      def default_branch
        @default_branch ||= discover_default_branch if @repo
      end

      def set_default_branch(branch_name)
        return false unless branch_names.include?(branch_name)

        @repo.head = @repo.branches[branch_name].canonical_name
        @default_branch = @repo.branches[branch_name].name
        true
      end

      # Alias to old method for compatibility
      def raw
        @repo
      end

      def path
        @path ||= @repo.path.gsub(/\/$/, "")
      end

      # TODO: gitaly
      # TODO: 暂不支持跨仓库提交，所以不使用 start_branch_name 和 start_repository
      # @param user [User]
      #
      # @return [Array] refname oldrev newrev
      def multi_action(
            user, branch_name:, message:, actions:,
            author_email: nil, author_name: nil,
            start_branch_name: nil, start_repository: self,
            force: false, ref_prefix: nil)
        in_locked_and_timed(10) do
          start_branch_name ||= branch_name
          start_commit = unless rugged.empty?
                           rugged.rev_parse(start_branch_name)
                         end

          index = Gitlab::Git::Index.new(self)
          parents = []

          if start_commit
            index.read_tree(start_commit.tree)
            parents = [start_commit.oid]
          end

          actions.each { |opts| index.apply(opts.delete(:action), opts) }

          committer = Gitlab::Git.gitee_committer
          user = Gitlab::Git::User.from_gitlab(user)
          author = Gitlab::Git.committer_hash(email: author_email || user.email, name: author_name || user.name)
          refname = (ref_prefix.presence || Gitlab::Git::BRANCH_REF_PREFIX) + branch_name
          options = {
            tree: index.write_tree,
            message: message,
            parents: parents,
            author: author,
            committer: committer,
            update_ref: refname,
          }

          oldrev = start_branch_name != branch_name ? Gitlab::Git::BLANK_SHA : parents.first
          newrev = Rugged::Commit.create(rugged, options)

          [refname, oldrev, newrev]
        end
      end

      # TODO gitaly
      # @param user [User]
      # @param commit [Gitlab::Git::Commit]
      # @param branch_name [String]
      # @param message [String]
      # @param start_branch_name [String]
      # @param start_repository [Gitlab::Git::Repository]
      def revert(user:, commit:, branch_name:, message:, start_branch_name:, start_repository:)
        user = Gitlab::Git::User.from_gitlab(user)
        start_commit = rugged.rev_parse(start_branch_name)

        revert_tree_id = check_revert_content(commit, start_commit.oid)
        raise CreateTreeError, I18n.translate('pull_request.cant_revert') unless revert_tree_id

        Rugged::Commit.create(rugged, {
          tree: revert_tree_id,
          parents: [start_commit.oid],
          author: Gitlab::Git.committer_hash(email: user.email, name: user.name),
          committer: Gitlab::Git.gitee_committer,
          message: message,
          update_ref: Gitlab::Git::BRANCH_REF_PREFIX + branch_name,
        })
      end

      # TODO gitaly
      def check_revert_content(target_commit, source_sha)
        args = [target_commit.oid, source_sha]
        args << { mainline: 1 } if target_commit.merge_commit?

        revert_index = rugged.revert_commit(*args)
        return false if revert_index.conflicts?

        tree_id = revert_index.write_tree(rugged)
        return false unless diff_exists?(source_sha, tree_id)

        tree_id
      end

      def diff_exists?(sha1, sha2)
        rugged.diff(sha1, sha2).size > 0
      end

      # @param oldrev [String]
      # @param newrev [String]
      # @return [Boolean]
      def force_push?(oldrev, newrev)
        return false if empty?
        return false if Gitlab::Git.blank_ref?(oldrev) || Gitlab::Git.blank_ref?(newrev)

        !ancestor?(oldrev, newrev)
      end

      # @param from [String]
      # @param from [String]
      # @return [Boolean]
      def ancestor?(from, to)
        return false if from.nil? || to.nil?
        merge_base(from, to) == from
      rescue Rugged::OdbError
        false
      end

      # TODO gitaly
      # @param from [String]
      # @param to   [String]
      # @return [String, nil]
      def merge_base(from, to)
        rugged.merge_base(from, to)
      rescue Rugged::ReferenceError, Rugged::InvalidError
        nil
      end

      # TODO gitaly
      # @param user [User]
      # @param source_sha [String] PR 源分支 sha
      # @param target_sha [String] PR 目标分支 sha
      # @param merge_ref [String] merge ref
      # @param message [String] commit message
      # @param first_parent_ref [String] 未使用
      # @return [String, nil]
      def merge_to_ref(user, source_sha, target_sha, merge_ref, message, first_parent_ref)
        commit_sha = create_merge_commit(user, target_sha, source_sha, message)
        return unless commit_sha

        rugged.references.create(merge_ref, commit_sha, force: true)
        commit_sha
      rescue Rugged::ReferenceError => e
        # ref 文件可能为空 https://gitee.com/oschina/dashboard/issues?id=I13YZH

        Gitlab::AppLogger.info "#{self.class.name}##{__method__} #{e.message}: " +
          "path=#{rugged.path}, merge_ref=#{merge_ref}"

        ref_path = rugged.path + merge_ref
        File.delete(ref_path) if File.size(ref_path).zero?

        rugged.references.create(merge_ref, commit_sha, force: true)
        commit_sha
      end

      # TODO gitaly
      # @param user [User]
      # @param source_sha [String] sha
      # @param target_branch [String] branch name
      # @param message [String]
      # @param block 未使用
      def merge(user, source_sha, target_branch, message, &block)
        in_locked_and_timed(20) do
          oldrev = rugged.rev_parse_oid(target_branch)
          newrev = create_merge_commit(user, oldrev, source_sha, message)
          return unless newrev

          refname = Gitlab::Git::BRANCH_REF_PREFIX + target_branch
          rugged.references.create(refname, newrev, force: true)

          yield newrev

          [refname, oldrev, newrev]
        end
      end

      # TODO gitaly
      # @param user [User]
      # @param squash_id [String] 未使用
      # @param branch [String] branch name
      # @param start_sha [String] sha
      # @param end_sha [String] sha
      # @param author [User]
      # @param message [message]
      def squash(user, squash_id, branch:, start_sha:, end_sha:, author:, message:)
        in_locked_and_timed(20) do
          oldrev = rugged.rev_parse_oid(branch)
          newrev = create_squash_commit(user, oldrev, end_sha, message, author)
          return unless newrev

          refname = Gitlab::Git::BRANCH_REF_PREFIX + branch
          rugged.references.create(refname, newrev, force: true)

          yield newrev

          [refname, oldrev, newrev]
        end
      end

      def close
        @repo && @repo.close
      end

      def commit(commit_id = 'HEAD')
        Gitlab::Git::Commit.find(self, commit_id)
      end

      # Limit: 0 implies no limit, thus all tag names will be returned
      def tag_names_contains_sha(sha, limit: 0)
        # TODO: gitaly
        raw_output = run_git!(%W[for-each-ref --contains=#{sha} --count=#{limit} --format=%(refname:short) refs/tags])
        encode!(raw_output).split("\n")
      end

      # Limit: 0 implies no limit, thus all branch names will be returned
      def branch_names_contains_sha(sha, limit: 0)
        # TODO: gitaly
        raw_output = run_git!(%W[for-each-ref --contains=#{sha} --count=#{limit} --format=%(refname:short) refs/heads])
        encode!(raw_output).split("\n")
      end

      # Get refs hash which key is the commit id
      # and value is a Gitlab::Git::Tag or Gitlab::Git::Branch
      # Note that both inherit from Gitlab::Git::Ref
      def refs_hash
        return @refs_hash if @refs_hash

        @refs_hash = Hash.new { |h, k| h[k] = [] }

        (tags + branches).each do |ref|
          next unless ref.commit

          @refs_hash[ref.commit.id] << ref.name
        end

        @refs_hash
      end

      def log(options)
        default_options = {
          limit: 10,
          offset: 0,
          path: nil,
          follow: false,
          skip_merges: false,
          after: nil,
          before: nil
        }
        options = default_options.merge(options)
        options[:limit] ||= 0
        options[:offset] ||= 0

        actual_ref = options[:ref] || 'HEAD'
        sha = sha_from_ref(actual_ref)

        # Return an empty array if the ref wasn't found
        return [] if sha.nil?

        # TODO: gitaly find_commits
        log_by_shell(sha, options).map do |commit_id|
          commit(commit_id)
        end
      end

      # Find the entry for +path+ in the tree for +commit+
      def tree_entry(commit, path)
        commit.tree.path(path)
      rescue Rugged::TreeError
        nil
      end

      # Return total commits count accessible from passed ref
      def commit_count(ref, options = {})
        count = options.blank? ? commit_count_by_walker(ref) : rev_list_by_shell(ref, options.merge(count: true))
        count.to_i
      rescue
        repository_commits_count
      end

      def repository_commits_count
        raw_output = run_git_with_timeout(%W(rev-list --all --count), Gitlab::Git::Popen::FAST_GIT_PROCESS_TIMEOUT).first.strip.to_i
      rescue Timeout::Error => e
        Gitlab::AppLogger.info "Gitlab::Git::Repository#repository_commits_count, path=#{path}, error=#{e}"
        0
      end

      # 危险写法，不允许传入任何用户自定义参数
      def contributors_count_by_shell
        start = Time.now
        result = `git --git-dir=#{path} log HEAD --pretty='%ae' | tr 'a-z' 'A-Z' | sort -u | wc -l`.strip.to_i
        Gitlab::TestSidekiqLogger.info_log "#{self.class.name}.#{__method__}. storage: #{storage}, relative_path: #{relative_path}. time: #{Time.now - start}"
        result
      rescue => e
        Gitlab::AppLogger.error "#{self.class.name}.#{__method__}: #{e}. storage: #{storage}, relative_path: #{relative_path}"
        0
      end

      # from, to 为 commit oid, from -> to,即 from 在 to 前
      # return (from, to)
      def commits_between(from, to)
        # TODO: move gitaly Gitlab::Git::Commit.between
        walker = Rugged::Walker.new(@repo)
        sha_from = @repo.rev_parse_oid(from) rescue nil
        sha_to = @repo.rev_parse_oid(to) rescue nil
        walker.push(sha_to)  if sha_to
        walker.hide(sha_from) if sha_from
        commits = walker.to_a
        walker.reset
        commits.map { |target| Gitlab::Git::Commit.decorate(self, target) }
      end

      def last_commit_for_path(sha, path)
        # TODO: gitaly
        path = '.' if path.blank?
        args = %W(rev-list --max-count=1 #{sha} -- #{path})
        commit_id = run_git_with_timeout(args, Gitlab::Git::Popen::FAST_GIT_PROCESS_TIMEOUT).first.strip
        commit(commit_id) if commit_id.present?
      rescue Timeout::Error => e
        Gitlab::AppLogger.info "Gitlab::Git::Repository#last_commit_for_path, path=#{path}, error=#{e}"
        nil
      end

      # @params revspec [String]
      def rev_parse_target(revspec)
        # TODO: gitaly 移除
        commit(revspec)
      end

      #代替lookup
      def sha_from_ref(revspec)
        begin
          object = @repo.rev_parse(revspec)
          if object.kind_of?(Rugged::Commit)
            object.oid
          elsif object.respond_to?(:target)
            sha_from_ref(object.target.oid)
          end
        rescue Exception=>e
          Gitlab::AppLogger.error "repository.rb, sha_from_ref, path:#{relative_path}, revspec:#{revspec}, error:#{e.to_s}"
          nil
        end
      end

      # Returns an Array of branch names
      # sorted by name ASC
      def branch_names(type=:local)
        branches(type).map(&:name)
      end

      def local_branches(sort_by: nil)
        branches_filter(filter: :local, sort_by: sort_by)
      end

      def tags_sorted_by(sort_by: nil)
        tags_filter(sort_by: sort_by)
      end

      # Returns an Array of Branches(:local, :remote, :all)
      def branches(type=:local)
        # TODO: gitaly
        rugged.branches.each(type).map do |rugged_ref|
          Gitlab::Git::Branch.new(self, rugged_ref)
        end.compact
      end

      def find_branch(name)
        # TODO: gitaly
        rugged_branch = rugged.branches[name]
        Gitlab::Git::Branch.new(self, rugged_branch) if rugged_branch
      end

      def create_branch(branch_name, target)
        # TODO: gitaly add_branch
        rugged_branch = @repo.branches.create(branch_name, target)
        Gitlab::Git::Branch.new(self, rugged_branch)
      end

      def rm_branch(branch_name)
        @repo.branches.delete(branch_name)
      end

      # Returns an Array of tag names
      def tag_names
        @repo.tags.map(&:name)
      end

      # Returns an Array of Tags
      def tags
        # TODO: gitaly
        @repo.references.each('refs/tags/*').map do |ref|
          obj = Gitlab::Git::Ref.dereference_object(ref.target)
          next unless obj.is_a?(Rugged::Commit)
          Gitlab::Git::Tag.new(self, ref, obj)
        end.compact
      end

      def create_tag(tag_name, target, tagger = nil , message = nil)
        # TODO: gitaly add_tag
        if tagger
          msg = {tagger: tagger, message: message.to_s}
        end
        rugged_tag = @repo.tags.create(tag_name, target, msg)
        target_commit = Gitlab::Git::Ref.dereference_object(rugged_tag.target)
        Gitlab::Git::Tag.new(self, rugged_tag, target_commit)
      end

      def rm_tag(tag_name)
        @repo.tags.delete(tag_name)
      end

      # ref_name must be canonical name
      def rm_ref(ref_name)
        @repo.references.delete(ref_name)
        true
      rescue
        false
      end

      # Returns an Array of branch and tag names
      def ref_names
        branch_names + tag_names
      end

      # @param sha [Gitlab::Git::Commit, String, Commit]
      # @param path [String]
      # @return [Gitlab::Git::Blob, nil]
      def blob_at(sha, path)
        Gitlab::Git::Blob.where(self, sha, path) unless Gitlab::Git.blank_ref?(sha)
      end

      # Returns url for submodule
      # 仅解析文件，不会验证子模块路径是否合法
      #
      # @param ref [Gitlab::Git::Commit, String, Commit]
      # @param path [String]
      # @return [nil, String]
      def submodule_url_for(ref, path)
        # TODO: gitaly
        blob = blob_at(ref, '.gitmodules')
        return if blob.blank?

        found_module = Gitlab::Git::GitmodulesParser.new(blob.data).parse[path]
        found_module && found_module['url']
      end

      def refs
        # branch 与 tag 同名时优先 tag，与 git 命令一致
        @refs ||= @repo.references.map{|ref| Gitlab::Git::Ref.new(self, ref.name, ref)}.reverse
      end

      # Ref names must start with `refs/`.
      def ref_exists?(ref_name)
        raise ArgumentError, 'invalid refname' unless ref_name.start_with?('refs/')
        @repo && @repo.references.exist?(ref_name)
      rescue Rugged::ReferenceError
        false
      end

      # Check out the specified ref. Valid options are:
      #
      # :b - Create a new branch at +start_point+ and set HEAD to the new
      # branch.
      #
      # * These options are passed to the Rugged::Repository#checkout method:
      #
      # :progress ::
      # A callback that will be executed for checkout progress notifications.
      # Up to 3 parameters are passed on each execution:
      #
      # - The path to the last updated file (or +nil+ on the very first
      # invocation).
      # - The number of completed checkout steps.
      # - The number of total checkout steps to be performed.
      #
      # :notify ::
      # A callback that will be executed for each checkout notification
      # types specified with +:notify_flags+. Up to 5 parameters are passed
      # on each execution:
      #
      # - An array containing the +:notify_flags+ that caused the callback
      # execution.
      # - The path of the current file.
      # - A hash describing the baseline blob (or +nil+ if it does not
      # exist).
      # - A hash describing the target blob (or +nil+ if it does not exist).
      # - A hash describing the workdir blob (or +nil+ if it does not
      # exist).
      #
      # :strategy ::
      # A single symbol or an array of symbols representing the strategies
      # to use when performing the checkout. Possible values are:
      #
      # :none ::
      # Perform a dry run (default).
      #
      # :safe ::
      # Allow safe updates that cannot overwrite uncommitted data.
      #
      # :safe_create ::
      # Allow safe updates plus creation of missing files.
      #
      # :force ::
      # Allow all updates to force working directory to look like index.
      #
      # :allow_conflicts ::
      # Allow checkout to make safe updates even if conflicts are found.
      #
      # :remove_untracked ::
      # Remove untracked files not in index (that are not ignored).
      #
      # :remove_ignored ::
      # Remove ignored files not in index.
      #
      # :update_only ::
      # Only update existing files, don't create new ones.
      #
      # :dont_update_index ::
      # Normally checkout updates index entries as it goes; this stops
      # that.
      #
      # :no_refresh ::
      # Don't refresh index/config/etc before doing checkout.
      #
      # :disable_pathspec_match ::
      # Treat pathspec as simple list of exact match file paths.
      #
      # :skip_locked_directories ::
      # Ignore directories in use, they will be left empty.
      #
      # :skip_unmerged ::
      # Allow checkout to skip unmerged files (NOT IMPLEMENTED).
      #
      # :use_ours ::
      # For unmerged files, checkout stage 2 from index (NOT IMPLEMENTED).
      #
      # :use_theirs ::
      # For unmerged files, checkout stage 3 from index (NOT IMPLEMENTED).
      #
      # :update_submodules ::
      # Recursively checkout submodules with same options (NOT
      # IMPLEMENTED).
      #
      # :update_submodules_if_changed ::
      # Recursively checkout submodules if HEAD moved in super repo (NOT
      # IMPLEMENTED).
      #
      # :disable_filters ::
      # If +true+, filters like CRLF line conversion will be disabled.
      #
      # :dir_mode ::
      # Mode for newly created directories. Default: +0755+.
      #
      # :file_mode ::
      # Mode for newly created files. Default: +0755+ or +0644+.
      #
      # :file_open_flags ::
      # Mode for opening files. Default:
      # <code>IO::CREAT | IO::TRUNC | IO::WRONLY</code>.
      #
      # :notify_flags ::
      # A single symbol or an array of symbols representing the cases in
      # which the +:notify+ callback should be invoked. Possible values are:
      #
      # :none ::
      # Do not invoke the +:notify+ callback (default).
      #
      # :conflict ::
      # Invoke the callback for conflicting paths.
      #
      # :dirty ::
      # Invoke the callback for "dirty" files, i.e. those that do not need
      # an update but no longer match the baseline.
      #
      # :updated ::
      # Invoke the callback for any file that was changed.
      #
      # :untracked ::
      # Invoke the callback for untracked files.
      #
      # :ignored ::
      # Invoke the callback for ignored files.
      #
      # :all ::
      # Invoke the callback for all these cases.
      #
      # :paths ::
      # A glob string or an array of glob strings specifying which paths
      # should be taken into account for the checkout operation. +nil+ will
      # match all files. Default: +nil+.
      #
      # :baseline ::
      # A Rugged::Tree that represents the current, expected contents of the
      # workdir. Default: +HEAD+.
      #
      # :target_directory ::
      # A path to an alternative workdir directory in which the checkout
      # should be performed.
      def checkout(ref, options = {}, start_point = "HEAD")
        if options[:b]
          @repo.branches.create(ref, start_point)
          options.delete(:b)
        end
        default_options = {strategy: :safe_create}
        @repo.checkout(ref, default_options.merge(options))
      end

      # Delete the specified branch from the repository
      def delete_branch(branch_name)
        @repo.branches.delete(branch_name)
      end

      # TODO gitaly
      # @param ref_names [Array] start with `refs/xxx`
      def delete_refs(*ref_names)
        ref_names.each do |ref_name|
          rugged.references.delete(ref_name)
        end
      end

      # Return an array of this repository's remote names
      def remote_names
        @repo.remotes.each_name.to_a
      end

      # Return a String containing the mbox-formatted diff between +from+ and
      # +to+
      def format_patch(from, to)
        from_sha = @repo.rev_parse_oid(from)
        to_sha = @repo.rev_parse_oid(to)
        commits_between(from_sha, to_sha).map do |commit|
          commit.raw_commit.to_mbox
        end.join("\n")
      rescue Rugged::InvalidError => ex
        if ex.message =~ /Commit \w+ is a merge commit/
          'Patch format is not currently supported for merge commits.'
        end
      end

      def to_diff(from, to)
        @repo.diff(from, to).each_patch.map do |p|
          p.to_s
        end.join("\n")
      end

      # TODO: gitaly
      # @param target_sha [String] sha
      # @param source_sha [String] sha
      # @return [Boolean]
      def can_be_merged?(target_sha, source_sha)
        raise 'Invalid merge target' unless target_sha
        raise 'Invalid merge source' unless source_sha

        merge_index = rugged.merge_commits(target_sha, source_sha)
        !merge_index.conflicts?
      rescue
        false
      end

      def has_commits?
        !empty?
      end

      def empty?
        !@repo || @repo.empty?
      end

      # 判断条件比较强(仓库是否存在HEAD,即存在提交)
      def repo_valid?
        @repo_valid ||= !!(@repo && ( @repo.head rescue nil))
      end

      # 判断条件较弱(包括空仓库)
      def repo_exist?
        !!@repo
      end

      # Discovers the default branch based on the repository's available branches
      #
      # - If no branches are present, returns nil
      # - If one branch is present, returns its name
      # - If two or more branches are present, returns current HEAD or master or first branch
      def discover_default_branch(default_branch = 'master')
        if empty?
          return nil
        end
        h = repo_head
        h_name = nil
        h_name = Gitlab::Git.ref_name(h.name) if h
        b = if branch_names.length == 0
              nil
            elsif branch_names.length == 1
              branch_names.first
            elsif branch_names.include?(h_name)
              h_name
            elsif branch_names.include?(default_branch)
              default_branch
            else
              branch_names.first
            end
        begin
          repo.head = "refs/heads/#{b}" if b!=nil && h_name != b
        rescue => e
          Gitlab::AppLogger.error "discover_default_branch, set head failed, error msg:#{e.to_s}"
        end
        b
      end

      def branch_exist?(name)
        branch_names.include? name
      end

      def tag_exist?(tag_name)
        tag_names.include?(tag_name)
      end

      def repo_head
        @repo.head
      rescue Rugged::ReferenceError
        nil
      end

      # @param sha [Gitlab::Git::Commit, String, Commit]
      # @param path [String, nil]
      # @param recursive [Boolean]
      # @return [Gitlab::Git::Tree, nil]
      def tree(sha = 'HEAD', path = nil, recursive: false)
        Gitlab::Git::Tree.where(self, sha, path, recursive: recursive)
      end

      # Archive Project to .tar.gz
      #
      # Already packed repo archives stored at
      # app_root/tmp/repositories/pr/project_name/project_name-commit-id.tag.gz
      #
      def archive_repo(ref, format: 'zip', prefix: nil, is_asyn: false)
        ref ||= 'HEAD'
        commit_id = sha_from_ref(ref)
        return nil unless commit_id

        git_archive_format = nil
        case format
        when 'tar.bz2', 'tbz', 'tbz2', 'tb2', 'bz2'
          extension = 'tar.bz2'
          pipe_cmd = %w(bzip2)
        when 'tar'
          extension = 'tar'
          pipe_cmd = %w(cat)
        when 'zip'
          extension = 'zip'
          git_archive_format = 'zip'
          pipe_cmd = %w(cat)
        else
          # everything else should fall back to tar.gz
          extension = 'tar.gz'
          pipe_cmd = %w(gzip -n)
        end
        # Build file path
        file_path = archive_path(commit_id, extension)

        # Put files into a directory before archiving
        temp_file_path = file_path.to_s + '.archiving'

        if File.exists?(temp_file_path)
          raise ArchivingError, 'archiving'
        end

        # Create file if not exists
        unless File.exists?(file_path)
          FileUtils.mkdir_p File.dirname(file_path)
          # Create the archive in temp file, to avoid leaving a corrupt archive
          # to be downloaded by the next user if we get interrupted while
          # creating the archive. Note that we do not care about cleaning up
          # the temp file in that scenario, because GitLab cleans up the
          # directory holding the archive files periodically.

          git_archive_cmd = %W(git --git-dir=#{@repo.path} archive)
          git_archive_cmd << "--prefix=#{prefix}/" if prefix
          git_archive_cmd << "--format=#{git_archive_format}" if git_archive_format
          git_archive_cmd += %W(-- #{commit_id})

          if is_asyn
            cache_key = archive_cache_key(commit_id, format)
            Rails.cache.write(cache_key, true, expires_in: 1.hour)
            ProjectPackageWorker.perform_async(temp_file_path, pipe_cmd, git_archive_cmd, cache_key)
          else
            Gitlab::Git::Repository.archive(temp_file_path, pipe_cmd, git_archive_cmd)
          end
        end

        file_path
      end

      # 获取打包后的文件的md5值
      def archive_md5(ref, preifx: nil)
        begin
          file_path = archive_repo(ref, prefix: prefix)
        rescue ArchivingError
          raise ArchivingError, 'archiving'
        end
        md5_path = archive_md5_path(file_path)
        retry_count = 0
        begin
          retry_count+=1
          md5 = File.read(md5_path)
          md5.strip
        rescue Errno::ENOENT
          generate_md5 file_path
          retry if retry_count <= 2
        end
      end

      def archive_path(sha, format)
        Rails.root.join('tmp', 'repositories', relative_path, "#{sha}.#{format}")
      end

      def unarchived?(sha, format)
        !archiving?(sha, format) && !archived?(sha, format)
      end

      def archiving?(sha, format)
        Rails.cache.read(archive_cache_key(sha, format))
      end

      def archived?(sha, format)
        File.exist?(archive_path(sha, format))
      end

      def archive_cache_key(sha, format = 'zip')
        ['project', relative_path, 'commit_id', sha, 'format', format].join(':')
      end

      def archive_captcha=(captcha)
        Rails.cache.write(archive_captcha_cache_key(captcha), true, expires_in: 1.hour)
      end

      def archive_captcha?(captcha)
        Rails.cache.read(archive_captcha_cache_key(captcha))
      end

      def expire_archive_captcha(captcha)
        Rails.cache.delete(archive_captcha_cache_key(captcha))
      end

      def archive_captcha_cache_key(captcha)
        ['project', relative_path, 'captcha', captcha].join(':')
      end

      # Return repo size in megabytes
      def size
        begin
          # use EnhanceUtils.repo_size get the size in mb
          size = EnhanceUtils.repo_size_mb(@repo.path)

          size>0.1 ? size : 0.1
        rescue
          0.1
        end
      end

      def languages
        result = nil

        linguist = Gitlab::Git::Linguist.new(rugged, rugged.head.target_id)
        Timeout.timeout(60) do
          linguist.linguist do |l|
            result = l.languages
          end
        end

        result
      rescue Timeout::Error => e
        Gitlab::AppLogger.info "#{self.class.name}##{__method__}: #{e}, #{rugged.path}"
        # NOTE 超时后不再分析该仓库语言
        linguist.disable_language_stats
        nil
      end

      # TODO: gitaly
      def ls_files(ref)
        commit(ref).tree.walk(:postorder).map do |root, entry|
          encode!(root + entry[:name]) if entry[:type] == :blob
        end.compact
      end

      def file_tree(ref)
        files = commit(ref).tree.walk(:preorder).map do |root, entry|
          {
            oid: entry[:oid],
            path: encode!(root + entry[:name]),
            name: encode!(entry[:name]),
            type: entry[:type]
          } if %w(tree blob).include?(entry[:type].to_s)
        end.compact

        format_file_tree(files).first
      end

      # Returns an array of BlobSnippets for files at the specified +ref+ that
      # contain the +query+ string.
      def search_files(query, ref = nil)
        # TODO: gitaly search_files_by_content
        greps = []
        ref ||= 'HEAD'
        populated_index(ref).each do |entry|
          # Discard submodules
          next if submodule?(entry)
          blob = @repo.lookup(entry[:oid])
          next if blob.binary?
          greps += build_greps(blob.content, query, ref, entry[:path])
        end
        greps
      end


      # Returns true if the index entry has the special file mode that denotes
      # a submodule.
      def submodule?(index_entry)
        index_entry[:mode] == 57344
      end

      # Return a Rugged::Index that has read from the tree at +ref_name+
      def populated_index(ref_name)
        tree = @repo.lookup(@repo.rev_parse_oid(ref_name)).tree
        index = @repo.index
        index.read_tree(tree)
        index
      end

      # Return an array of BlobSnippets for lines in +file_contents+ that match
      # +query+
      def build_greps(file_contents, query, ref, filename)
        query = EncodingHelper.encode!(query)
        greps = []
        file_contents.split("\n").each_with_index do |line, i|
          next unless line.force_encoding('utf-8').match(/#{Regexp.escape(query)}/i)
          greps << Gitlab::Git::BlobSnippet.new(
          ref,
          file_contents.split("\n")[i - 3..i + 3],
          i - 2,
          filename
          )
        end
        greps
      end

      # Return an array of Diff objects that represent the diff
      # between +from+ and +to+.  See Diff::filter_diff_options for the allowed
      # diff options.  The +options+ hash can also include :break_rewrites to
      # split larger rewrites into delete/add pairs.
      def diff(from, to, options = {}, *paths)
        iterator = diff_patches(from, to, options, *paths)
        Gitlab::Git::DiffCollection.new(iterator, options)
      end

      # Return the diff between +from+ and +to+ in a single patch string.
      def diff_text(from, to, *paths)
        # NOTE: It would be simpler to use the Rugged::Diff#patch method, but
        # that formats the diff text differently than Rugged::Patch#to_s for
        # changes to binary files.
        @repo.diff(from, to, paths: paths).each_patch.map do |p|
          p.to_s
        end.join("\n")
      end

      # Return the Rugged patches for the diff between +from+ and +to+.
      def diff_patches(from, to, options = {}, *paths)
        options ||= {}
        break_rewrites = options[:break_rewrites]
        actual_options = Gitlab::Git::Diff.filter_diff_options(options.merge(paths: paths))

        diff = @repo.diff(from, to, actual_options)
        diff.find_similar!(break_rewrites: break_rewrites)
        diff.each_patch
      end

      # fetch repository
      #
      # @param url [String] remote url
      # @param refmap [Symbol] `nil`: branches and tags, `:all_refs`: all references
      # @param git_timeout [Integer] seconds
      # @param http_auth [Hash] `{ username: '', password: '' }`
      # @throws Exception
      def fetch_remote(url, refmap: nil, git_timeout: 1800, http_auth: {}, env: {})
        fetch_refs = if refmap == :all_refs
                       %w[+refs/*:refs/*]
                     else
                       %w[+refs/heads/*:refs/heads/* +refs/tags/*:refs/tags/*]
                     end
        fetch_url = get_fetch_url(url, http_auth)

        Timeout.timeout(git_timeout) do
          fetch_result = run_git(['fetch', fetch_url, *fetch_refs, '--progress'], env: env)
          after_fetch_handle!(fetch_result)
        end
      end

      # safe remove unused tmp_pack file under objects/pack/
      #  what file is not used by some progress
      #  doc:https://gitee.com/ipvb/enhanceutils/blob/master/docs/api.md
      def remove_fetch_tmp_pack
        EnhanceUtils.remove_fetch_tmp_pack(path)
      end

      # remove unused receive-pack file
      #  doc: https://gitee.com/ipvb/enhanceutils/blob/master/docs/api.md
      def remove_incoming_dir
        EnhanceUtils.remove_incoming_dir(path)
      end

      # TODO: gitaly
      #   gitaly.call(:gc, repository)
      # repository gc
      def gc
        remove_fetch_tmp_pack
        remove_incoming_dir
        run_git(["gc", "--prune=now"])
      end

      def git_internal_url
        "git://#{storage}/#{relative_path}.git"
      end

      # TODO: gitaly
      # @param source_repository [Gitlab::Git::Repository]
      # @param source_branch_name [String] `refs/heads/xxx`, branch name
      # @param local_ref [String] `refs/xxx`
      def fetch_source_branch!(source_repository, source_branch_name, local_ref, is_canonical_name: false)
        rugged_fetch_source_branch(source_repository, source_branch_name, local_ref, is_canonical_name: is_canonical_name)
      rescue => ex
        remove_fetch_tmp_pack
        raise ex
      end

      # TODO: gitlay
      def raw_blame(sha, path)
        raw_output, _status = run_git(%W[blame -p #{sha} -- #{path}])
        raw_output
      end

      # @param target_branch_name [String] `refs/heads/xxx`, branch name, commit id
      # @param source_repository [Gitlab::Git::Repository]
      # @param source_branch_name [String], `refs/heads/xxx`, branch name
      # @param straight [Boolean]
      def compare_source_branch(target_branch_name, source_repository, source_branch_name, straight:)
        reachable_ref =
          if source_repository == self
            source_branch_name
          else
            # TODO gitaly
            # 查看 commit id 是否已经存在
          end

        return compare(target_branch_name, reachable_ref, straight: straight) if reachable_ref

        tmp_ref = "refs/tmp/#{SecureRandom.hex}"

        return unless fetch_source_branch!(source_repository, source_branch_name, tmp_ref)

        compare(target_branch_name, tmp_ref, straight: straight)
      ensure
        delete_refs(tmp_ref) if tmp_ref
      end

      def method_missing(m, *args, &block)
        @repo.send(m, *args, &block)
      end

      protected

      # run git无法在执行过程中捕获异常
      #  需要根据返回值抛出相应异常
      def after_fetch_handle!(msg)
        return if msg.last == 0
        raise NetworkError if msg.first =~ /Could not resolve host/im
        raise AccountError if msg.first =~ /Invalid username or password/im
        raise UnknownError, msg.first
      end

      # 格式化用于fetch的url
      #   将用户名和密码格式化到url中
      def get_fetch_url(url, http_auth)
        format_url = Addressable::URI.parse(url)
        return url if format_url.scheme == "git" || http_auth[:username].blank? || http_auth[:password].blank?
        format_url.user = http_auth[:username]
        format_url.password = http_auth[:password]
        format_url.normalize.to_s
      end

      # https://gitee.com/oschina/dashboard/issues?id=I11DLT
      # * Locks the repo
      # * Yields the prepared satellite repo
      def in_locked_and_timed(time)
        Timeout.timeout(time) do
          lock do
            return yield
          end
        end
      rescue Timeout::Error
        raise Gitlab::Git::Index::IndexError, 'Operation timeout'
      end

      # * Locks the repo
      # * Yields
      def lock
        File.open(lock_file, "w+") do |f|
          f.flock(File::LOCK_EX)
          yield
        end
      end

      # save the lock file in tmp/locakdir
      # file name like: repo_123213.lock
      def lock_file
        Rails.root.join('tmp/lockdir', "repo_#{relative_path.gsub('/','@')}.lock")
      end

      # 根据文件路径,在同目录下生成md5文件
      def generate_md5(file_path)
        self.class.generate_md5(file_path)
      end

      # 传入文件路径,返回md5的地址
      def archive_md5_path(file_path)
        if File.exist?(file_path)
          "#{file_path}.md5"
        end
      end

      private

      def rugged_fetch_source_branch(source_repository, source_branch_name, local_ref, is_canonical_name: false)
        source_ref = if is_canonical_name || Gitlab::Git.branch_ref?(source_branch_name)
                       source_branch_name
                     else
                       Gitlab::Git::BRANCH_REF_PREFIX + source_branch_name
                     end

        if self == source_repository
          source_sha = rugged.rev_parse_oid(source_ref)
          rugged.references.create(local_ref, source_sha, force: true)
        else
          remote = remotes.create_anonymous(source_repository.git_internal_url)
          remote.fetch("+#{source_ref}:#{local_ref}")
        end
      rescue Rugged::ReferenceError => e
        # ref 文件可能为空 https://gitee.com/oschina/dashboard/issues?id=I11DLT

        Gitlab::AppLogger.info "#{self.class.name}##{__method__} #{e.message}: " +
                                   "path=#{rugged.path}, source_branch_name=#{source_branch_name}, local_ref=#{local_ref}"

        ref_path = rugged.path + local_ref
        File.delete(ref_path) if File.size(ref_path).zero?

        remote.fetch("+#{source_ref}:#{local_ref}") if remote
      end

      def user_to_committer(user)
        user = Gitlab::Git::User.from_gitlab(user)
        Gitlab::Git.committer_hash(email: user.email, name: user.name)
      end

      def compare(base_ref, head_ref, straight:)
        Gitlab::Git::Compare.new(self, base_ref, head_ref, straight: straight)
      end

      def create_commit(params = {})
        Rugged::Commit.create(rugged, params)
      end

      def create_merge_commit(user, our_commit, their_commit, message)
        raise 'Invalid merge target' unless our_commit
        raise 'Invalid merge source' unless their_commit

        merge_index = rugged.merge_commits(our_commit, their_commit)
        return if merge_index.conflicts?

        create_commit(
          parents: [our_commit, their_commit],
          tree: merge_index.write_tree(rugged),
          author: user_to_committer(user),
          committer: Gitlab::Git.gitee_committer,
          message: message
        )
      end

      def create_squash_commit(user, our_commit, their_commit, message, author)
        raise 'Invalid merge target' unless our_commit
        raise 'Invalid merge source' unless their_commit

        merge_index = rugged.merge_commits(our_commit, their_commit)
        return if merge_index.conflicts?

        create_commit(
          parents: [our_commit],
          tree: merge_index.write_tree(rugged),
          author: user_to_committer(author),
          committer: user_to_committer(user),
          message: message
        )
      end

      def run_git(args, chdir: path, env: {}, nice: false, lazy_block: nil, &block)
        cmd = [Gitlab.config.git.bin_path, *args]
        cmd.unshift("nice") if nice

        popen(cmd, chdir, env, lazy_block: lazy_block, &block)
      end

      def run_git!(args, chdir: path, env: {}, nice: false, lazy_block: nil, &block)
        output, status = run_git(args, chdir: chdir, env: env, nice: nice, lazy_block: lazy_block, &block)

        raise GitError, output unless status.zero?

        output
      end

      def run_git_with_timeout(args, timeout, env: {})
        popen_with_timeout([Gitlab.config.git.bin_path, *args], timeout, path, env)
      end

      def log_by_shell(sha, options)
        # TODO: gitaly find_commits
        limit = options[:limit].to_i
        offset = options[:offset].to_i
        use_follow_flag = options[:follow] && options[:path].present?

        # We will perform the offset in Ruby because --follow doesn't play well with --skip.
        # See: https://gitlab.com/gitlab-org/gitlab-ce/issues/3574#note_3040520
        offset_in_ruby = use_follow_flag && options[:offset].present?
        limit += offset if offset_in_ruby

        cmd = %w[log]
        cmd << "--max-count=#{limit}" unless limit == 0
        cmd << '--format=%H'
        cmd << "--skip=#{offset}" unless offset_in_ruby
        cmd << '--follow' if use_follow_flag
        cmd << '--no-merges' if options[:skip_merges]
        cmd << "--after=#{options[:after].iso8601}" if options[:after]
        cmd << "--before=#{options[:before].iso8601}" if options[:before]
        cmd += Array(options[:author]).map{|author| "--author=#{author}"} if options[:author].present?
        cmd << sha
        cmd += Array(options[:path]).unshift('--') if options[:path].present?

        raw_output, _status = run_git(cmd, chdir: path)
        raw_output = raw_output.split("\n").reject { |line| line.start_with?('warning:') }
        offset_in_ruby ? raw_output.drop(offset) : raw_output
      end

      def rev_list_by_shell(sha, options = {})
        cmd = ['rev-list', sha]
        cmd << '--count' if options[:count]
        cmd << '--follow' if options[:follow] && options[:path].present?
        cmd << '--no-merges' if options[:skip_merges]
        cmd << "--after=#{options[:after].iso8601}" if options[:after]
        cmd << "--before=#{options[:before].iso8601}" if options[:before]
        cmd += Array(options[:author]).map{|author| "--author=#{author}"} if options[:author].present?
        cmd += Array(options[:path]).unshift('--') if options[:path].present?

        raw_output, _status = run_git(cmd, chdir: path)
        raw_output
      end

      def commit_count_by_walker(sha)
        walker = Rugged::Walker.new(@repo)
        walker.push(@repo.rev_parse_oid(sha))
        walker.count
      end

      def format_file_tree(files, index = 0, dir_layer = 0)
        format_files = []
        while index < files.length
          if files[index][:type] == :tree
            result = format_file_tree(files, index + 1, files[index][:path].split('/').length)
            files[index][:children] = result[0]
            format_files << files[index]
            index = result[1]
          else
            break if files[index][:path].split('/').length - 1 != dir_layer
            format_files << files[index]
            index += 1
          end
          break if files[index].nil? || (files[index][:type] == :tree && files[index][:path].split('/').length <= dir_layer)
        end
        [format_files, index]
      end

      def branches_filter(filter: nil, sort_by: nil)
        sort_tags_or_branches(branches(filter), sort_by)
      end

      def tags_filter(fileter: nil, sort_by: nil)
        sort_tags_or_branches(tags, sort_by)
      end

      def sort_tags_or_branches(target, sort_by)
        case sort_by
        when 'name_asc'
          target.sort do |a, b|
            a.name <=> b.name
          end
        when 'name_desc'
          target.sort do |a, b|
            b.name <=> a.name
          end
        when 'updated_asc'
          target.sort do |a, b|
            (a.commit.try(:committed_date) || Time.now) <=> (b.commit.try(:committed_date) || Time.now)
          end
        when 'updated_desc'
          target.sort do |a, b|
            (b.commit.try(:committed_date) || Time.now) <=> (a.commit.try(:committed_date) || Time.now)
          end
        else
          target
        end
      end
    end
  end
end
