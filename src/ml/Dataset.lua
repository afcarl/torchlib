local xlua = require 'xlua'
local torch = require 'torch'
local Set = tl.Set

--- @module Dataset
-- Implementation of dataset container.
-- The goal of this class is to provide utilities for manipulating generic datasets. in particular, a
-- dataset can be a list of examples, each with a fixed set of fields.
local Dataset, parent = torch.class('tl.Dataset', 'tl.Object')


--- Constructor.
-- 
-- @arg {table[any:any]} fields - a table containing key value pairs
-- 
-- Each value is a list of tensors and `value[i]` contains the value corresponding to the `i`th example.
-- 
-- Example:
--
-- Suppose we have two examples, with fields `X` and `Y`. The first example has `X=[1, 2, 3], Y=1` while
-- the second example has `X=[4, 5, 6, 7, 8}, Y=4`. To create a dataset:
-- 
-- @code {lua}
-- X = {torch.Tensor{1, 2, 3}, torch.Tensor{4, 5, 6, 7, 8}}
-- Y = {1, 4}
-- d = Dataset{X = X, Y = Y}
-- 
-- Of course, in practice the fields can be arbitrary, so long as each field is a table and has an equal
-- number of elements.
function Dataset:__init(fields)
  self.fields = {}
  for k, v in pairs(fields) do
    table.insert(self.fields, k)
    self[k] = v
    if #self.fields > 1 then
      local err = 'field '..k..' has length '..#v..' but field '..self.fields[1]..' has length '..#self[self.fields[1]]
      assert(#v == #self[self.fields[1]], err)
    end
  end
end


--- Creates a dataset from CONLL format.
-- 
-- @arg {string} fname - path to CONLL file
-- @returns {Dataset} loaded dataset
-- 
-- The format is as follows:
-- 
-- @code {text}
-- # word  subj  subj_ner  obj obj_ner stanford_pos  stanford_ner  stanford_dep_edge stanford_dep_governor
-- per:city_of_birth
-- - - - - - : O punct 1
-- 20  - - - - CD  DATE  ROOT  -1
-- : - - - - : O punct 1
-- Alexander SUBJECT PERSON  - - NNP PERSON  compound  4
-- Haig  SUBJECT PERSON  - - NNP PERSON  dep 1
-- , - - - - , O punct 4
-- US  - - - - NNP LOCATION  compound  7
-- secretary - - - - NN  O appos 4
-- 
-- That is, the first line is a tab delimited header, followed by examples separated by a blank line.
-- The first line of the example is the class label. The rest of the rows correspond to tokens and their associated attributes.
-- 
-- Example:
-- 
-- @code {lua}
-- dataset = Dataset.from_conll('data.conll')
function Dataset.from_conll(fname)
  local file = assert(io.open(fname), fname .. ' does not exist!')
  local header = file:read():split('\t')
  header[1] = header[1]:sub(3)  -- remove the '# '
  local get_fields = function()
    local fields = {}
    for _, heading in ipairs(header) do fields[heading] = {} end
    return fields
  end
  local fields = get_fields()
  fields.label = {}

  local line, linenum = file:read(), 2  -- first line's the header
  local example = get_fields()
  local labeled = false
  local submit_example = function()
    for k, v in pairs(fields) do table.insert(v, example[k]) end
    table.insert(fields.label, example.label)
    example = get_fields()
    labeled = false
  end
  while line do
    if #line:split('\t') == 1 and not labeled then  -- this is a label
      table.insert(fields.label, line)
      labeled = true
    elseif line == '' then  -- we just finished collecting an example
      submit_example()
    else
      local cols = line:split('\t')
      for i, heading in ipairs(header) do
        assert(cols[i], 'line '..linenum..' is missing column '..i..' ('..heading..'): '..line)
        table.insert(example[heading], cols[i])
      end
    end
    line = file:read()
    linenum = linenum + 1
  end
  submit_example()
  return Dataset.new(fields)
end


--- @returns {string} string representation
function Dataset:__tostring__()
  local s = parent.__tostring__(self) .. "("
  for i, k in ipairs(self.fields) do
    s = s .. k
    if i < #self.fields then
      s = s .. ', '
    else
      s = s .. ') of size ' .. self:size()
    end
  end
  return s
end

--- @returns {int} number of examples in the dataset
function Dataset:size()
  assert(#self.fields > 0, 'Dataset is empty and does not have any fields!')
  return #self[self.fields[1]]
end

--- Returns a table of `k` folds of the dataset.
-- 
-- @arg {int} k - how many folds to create
-- @returns {table[table]} tables of indices corresponding to each fold
-- 
-- Each fold consists of a random table of indices corresponding to the examples in the fold.
function Dataset:kfolds(k)
  local indices = torch.randperm(self:size()):long()
  return table.map(indices:chunk(k), function(l) return l:totable() end)
end

--- Copies out a new Dataset which is a view into the current Dataset.
-- 
-- @arg {vararg} vararg - each argument is a tables of integer indices corresponding to a view
-- @returns {vararg(Datasets)} one dataset view for each list of indices
-- 
-- Example:
-- 
-- Suppose we already have a `dataset` and would like to split it into two datasets. We want
-- the first dataset `a` to contain examples 1 and 3 of the original dataset. We want the
-- second dataset `b` to contain examples 1, 2 and 3 (yes, duplicates are supported).
-- 
-- @code {lua}
-- a, b = dataset:view({1, 3}, {1, 2, 3})
function Dataset:view(...)
  local indices = table.pack(...)
  local datasets = {}
  for i, t in ipairs(indices) do
    local fields = {}
    for _, k in ipairs(self.fields) do
      fields[k] = table.select(self[k], t, {forget_keys=true})
    end
    table.insert(datasets, Dataset.new(fields))
  end
  return table.unpack(datasets)
end

--- Creates a train split and a test split given the train indices.
-- 
-- @arg {table[int]} train_indices - a table of integers corresponding to indices of training examples
-- @returns {Dataset, Dataset} train and test dataset views
--
-- Other examples will be used as test examples.
-- 
-- Example:
-- 
-- Suppose we'd like to split a `dataset` and use its 1, 2, 4 and 5th examples for training.
-- 
-- @code
-- train, test = dataset:train_dev_split{1, 2, 4, 5}
function Dataset:train_dev_split(train_indices)
  local train = Set(train_indices)
  local all = Set(torch.range(1, self:size()):totable())
  return self:view(train:totable(), all:subtract(train):totable())
end

--- Reindexes the dataset accoring to the new indices.
-- 
-- @arg {table[int]} indices - indices to re-index the dataset with
-- @returns {Dataset} modified dataset
-- 
-- Example:
-- 
-- Suppose we have a `dataset` of 5 examples and want to swap example 1 with example 5.
-- 
-- @code
-- dataset:index{5, 2, 3, 4, 1}
function Dataset:index(indices)
  for _, k in ipairs(self.fields) do
    local shuffled = {}
    for _, i in ipairs(indices) do
      table.insert(shuffled, self[k][i])
    end
    self[k] = shuffled
  end
  return self
end

--- Shuffles the dataset in place
-- @returns {Dataset} modified dataset
function Dataset:shuffle()
  local indices = torch.randperm(self:size()):totable()
  return self:index(indices)
end

--- Sorts the examples in place by the length of the requested field.
-- @arg {string} field - field to sort with
-- @returns {Dataset} modified dataset
--
-- It is assumed that the field contains torch Tensors. Sorts in ascending order.
function Dataset:sort_by_length(field)
  assert(self[field], field .. ' is not a valid field')
  local lengths = torch.Tensor(table.map(self[field], function(a) return a:size(1) end))
  local sorted, indices = torch.sort(lengths)
  return self:index(indices:totable())
end

--- Prepends shorter tensors in a table of tensors with `PAD` such that each tensor in the batch are of the same length.
-- 
-- @arg {table[torch.Tensor]} tensors - tensors of varying lengths
-- 
-- @arg {int=0} PAD - index to pad missing elements with.
-- 
-- Example:
-- 
-- @code
-- X = {torch.Tensor{1, 2, 3}, torch.Tensor{4}}
-- Y = Dataset.pad(X, 0)
-- 
-- `Y` is now:
-- 
-- @code
-- torch.Tensor{{1, 2, 3}, {0, 0, 4}}
function Dataset.pad(tensors, PAD)
  PAD = PAD or 0
  local lengths = torch.Tensor(table.map(tensors, function(a) return a:size(1) end))
  local min, max = lengths:min(), lengths:max()
  local X = torch.Tensor(#tensors, max):fill(PAD)
  for i, x in ipairs(tensors) do
    -- pad the beginning with zeros
    X[{i, {max-x:size(1)+1, max}}] = x
  end
  return X
end

--- Creates a batch iterator over the dataset.
-- 
-- @arg {int} batch_size - maximum size of each batch
-- 
-- Example:
-- 
-- @code
-- d = Dataset{X=X, Y=Y}
-- for batch, batch_end in d:batches(5) do
--   print(batch.X)
--   print(batch.Y)
-- end
function Dataset:batches(batch_size)
  local batch_start, batch_end = 1
  return function()
    local batch = {}
    if batch_start <= self:size() then
      batch_end = batch_start + batch_size - 1
      for _, k in ipairs(self.fields) do
        batch[k] = table.select(self[k], tl.range(batch_start, batch_end), {forget_keys=true})
      end
      batch_start = batch_end + 1
      return batch, math.min(batch_end, self:size())
    else
      return nil
    end
  end
end

--- Applies transformations to fields in the dataset.
-- 
-- @arg {table[string:function]} transforms - a key-value map where a key is a field in the dataset and the corresponding value
-- is a function that is to be applied to the requested field for each example.
-- @arg {boolean=} in_place - whether to apply the transformation in place or return a new dataset
--
-- Example:
-- 
-- @code
-- dataset = Dataset{names={'alice', 'bob', 'charlie'}, id={1, 2, 3}}
-- dataset2 = dataset:transform{names=string.upper, id=function(x) return x+1 end}
-- 
-- @description
-- `dataset2` is now `Dataset{names={'ALICE', 'BOB', 'CHARLIE'}, id={2, 3, 4}}` while `dataset` remains unchanged.
-- 
-- @code
-- dataset = Dataset{names={'alice', 'bob', 'charlie'}, id={1, 2, 3}}
-- dataset2 = dataset:transform({names=string.upper}, true)
-- 
-- @description
-- `dataset` is now `Dataset{names={'ALICE', 'BOB', 'CHARLIE'}, id={1, 2, 3}}` and `dataset2` refers to `dataset`.
function Dataset:transform(transforms, in_place)
  local d = self
  if not in_place then d = tl.deepcopy(self) end
  for k, f in pairs(transforms) do
    local ex = assert(d[k], 'transform '..k..' is not a valid field')
    for i, e in ipairs(ex) do ex[i] = f(e) end
  end
  return d
end

return Dataset
