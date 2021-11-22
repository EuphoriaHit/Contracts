const path = require('path');
const fs = require('fs');

const directoryPath = path.join(__dirname, 'build/contracts');

fs.readdir(directoryPath, function (err, files) {
    //handling error
    if (err) {
        return console.log('Unable to scan directory: ' + err);
    } 
    files.forEach(function (file) {

        fs.readFile(directoryPath + "/" + file, function(err, data)
        {
            var parsedData = JSON.parse(data);
            
            if(parsedData.abi.length != 0)
            {
                fs.writeFile(`./abis/${file}`, JSON.stringify(parsedData.abi), function (err) {
                    if (err) return console.log(err);
                });
            }
            
        });
    });
});
