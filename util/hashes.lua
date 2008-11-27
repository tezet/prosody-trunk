
local softreq = function (...) local ok, lib =  pcall(require, ...); if ok then return lib; else return nil; end end
local error = error;

module "hashes"

local md5 = softreq("md5");
if md5 then
	if md5.digest then
		local md5_digest = md5.digest;
		local sha1_digest = sha1.digest;
		function _M.md5(input)
			return md5_digest(input);
		end
		function _M.sha1(input)
			return sha1_digest(input);
		end
	elseif md5.sumhexa then
		local md5_sumhexa = md5.sumhexa;
		function _M.md5(input)
			return md5_sumhexa(input);
		end
	else
		error("md5 library found, but unrecognised... no hash functions will be available", 0);
	end
else
	error("No md5 library found. Install md5 using luarocks, for example", 0);
end

return _M;
