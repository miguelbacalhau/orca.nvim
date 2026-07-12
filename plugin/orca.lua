-- Command surface only; the module loads on first use, so startup cost is
-- effectively zero for sessions that never review.
if vim.g.loaded_orca then return end
vim.g.loaded_orca = true

local function orca() return require('orca') end

vim.api.nvim_create_user_command('OrcaReview', function(opts)
  orca().review(opts.args)
end, { nargs = '?', desc = 'Review a branch: merge-base diff of <base>...<head> (default <trunk>...HEAD)' })

vim.api.nvim_create_user_command('OrcaReviewClose', function()
  orca().close()
end, { desc = 'End the review session and clean up' })

vim.api.nvim_create_user_command('OrcaReviewNext', function()
  orca().next()
end, { desc = 'Open the next changed file as a diff pair' })

vim.api.nvim_create_user_command('OrcaReviewPrev', function()
  orca().prev()
end, { desc = 'Open the previous changed file as a diff pair' })

vim.api.nvim_create_user_command('OrcaComment', function(opts)
  orca().comment(opts.line1, opts.line2)
end, { range = true, desc = 'Create or edit the review comment on this line (visual mode: on the range)' })

vim.api.nvim_create_user_command('OrcaCommentDelete', function()
  orca().comment_delete()
end, { desc = 'Delete the review comment under the cursor' })
